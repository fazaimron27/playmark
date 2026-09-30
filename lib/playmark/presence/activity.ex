defmodule Playmark.Presence.Activity do
  @moduledoc """
  Builds the Discord activity object for a video being watched.

  Pure: no IO, no clock. `build/1` takes the card the TUI published plus
  whatever anchoring the GenServer has, and returns the `activity` object for
  `SET_ACTIVITY`. The clock-dependent parts — `start_ms`, `duration_ms` — are
  computed by the caller and passed in, which is what makes the arithmetic
  testable without waiting for anything.

  ## Two rules that are easy to get wrong

  **A malformed URL makes Discord reject the whole activity**, because the field
  is validated for URI syntax alone. Every optional URL is therefore *omitted*
  rather than sent blank — so the URL is passed through
  `Playmark.YouTube.validate/1` and dropped when it fails.

  **Truncation units differ by field.** Visible text (`details`, `state`) is
  measured in runes, so a CJK or emoji title is not cut short. The hover text
  (`assets.large_text`) is capped in *bytes*, because that is Discord's own
  limit — and a cut mid-codepoint is itself malformed, so it backs off to the
  boundary.

  ## Why milliseconds

  Timestamps are Unix milliseconds on both fields, always. Discord accepts
  seconds too — it multiplies a seconds value by 1000 before echoing it back —
  so this is a consistency rule rather than a correctness one: mixing the two
  units within one activity re-anchors the progress bar.

  Presence is YouTube-only, so this module assumes a YouTube URL and simply
  omits the link fields for anything else. Deciding *whether* to publish is the
  TUI's job (see `Playmark.TUI.PlaybackActions.publish_presence/1`).
  """

  alias Playmark.YouTube

  @details_max_runes 48
  @state_max_runes 40
  @hover_max_bytes 128

  @thumbnail "https://i.ytimg.com/vi/~s/mqdefault.jpg"

  @watch_label "Watch on YouTube"

  @doc """
  The activity object for `card`, or `nil` when there is nothing to show.

  A card with no title is not publishable: Discord requires `details`.
  """
  def build(%{title: title, url: url} = card)
      when is_binary(title) and title != "" and is_binary(url) do
    %{
      "type" => 3,
      "status_display_type" => 1,
      "instance" => false,
      "details" => truncate_runes(title, @details_max_runes)
    }
    # URL-bearing fields are added first: the assets and the button below both
    # read `details_url`, so a URL that failed validation removes all three at
    # once rather than leaving a card with a link to nowhere.
    |> put_details_url(url)
    |> put_state(card)
    |> put_timestamps(card)
    |> put_assets(card, title)
    |> put_button()
  end

  def build(_card), do: nil

  defp put_details_url(activity, url) do
    case YouTube.validate(url) do
      {:ok, valid} -> Map.put(activity, "details_url", valid)
      {:error, _reason} -> activity
    end
  end

  defp put_state(activity, %{author: author}) when is_binary(author) and author != "" do
    Map.put(activity, "state", truncate_runes(author, @state_max_runes))
  end

  defp put_state(activity, _card), do: activity

  defp put_timestamps(activity, %{start_ms: start_ms} = card) when is_integer(start_ms) do
    Map.put(activity, "timestamps", timestamps(start_ms, Map.get(card, :duration_ms)))
  end

  defp put_timestamps(activity, _card), do: activity

  # `end` is added only for a finite, positive duration. A live stream reports
  # `nil`, and a zero duration would put the bar already finished.
  defp timestamps(start_ms, duration_ms) do
    base = %{"start" => start_ms}

    if is_integer(duration_ms) and duration_ms > 0 do
      Map.put(base, "end", start_ms + duration_ms)
    else
      base
    end
  end

  defp put_assets(activity, %{video_id: video_id}, title)
       when is_binary(video_id) and video_id != "" do
    assets = %{
      "large_image" => thumbnail(video_id),
      "large_text" => truncate_bytes(title, @hover_max_bytes)
    }

    # `large_url` is present only when `details_url` survived validation, which
    # is what keeps the image clickable instead of pointing at nothing.
    assets =
      case activity do
        %{"details_url" => url} -> Map.put(assets, "large_url", url)
        _other -> assets
      end

    Map.put(activity, "assets", assets)
  end

  defp put_assets(activity, _card, _title), do: activity

  defp put_button(%{"details_url" => url} = activity) do
    Map.put(activity, "buttons", [%{"label" => @watch_label, "url" => url}])
  end

  defp put_button(activity), do: activity

  defp thumbnail(video_id), do: String.replace(@thumbnail, "~s", video_id)

  defp truncate_runes(text, max) do
    case String.length(text) do
      length when length > max -> String.slice(text, 0, max)
      _length -> text
    end
  end

  # A byte cap, with the cut backed off to a codepoint boundary: half a
  # codepoint is itself malformed, so Discord would reject the activity.
  defp truncate_bytes(text, max) do
    if byte_size(text) <= max do
      text
    else
      text |> binary_part(0, max) |> drop_partial_codepoint()
    end
  end

  defp drop_partial_codepoint(binary) do
    if String.valid?(binary) do
      binary
    else
      drop_partial_codepoint(binary_part(binary, 0, byte_size(binary) - 1))
    end
  end
end
