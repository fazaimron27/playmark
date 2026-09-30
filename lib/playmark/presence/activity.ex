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

  **Text is capped in UTF-16 code units.** `details`, `state`, and the hover
  `assets.large_text` share Discord's limit of 128, and that limit counts
  UTF-16 code units — not runes and not bytes. Measured against a real client:
  128 ASCII runes are accepted and 129 rejected; 128 CJK runes are accepted
  despite being 384 bytes; 128 astral emoji are rejected, because each costs
  two units. Capping by rune count would let an emoji-heavy title through, and
  Discord rejects the *whole activity* — not the offending field — so the card
  would disappear rather than shorten. An over-long value is cut to fit with a
  trailing `…`, which is counted inside the budget for the same reason: a
  truncation that lands back over the limit is a rejection, not a truncation.

  ## The channel link

  The `state` line carries the channel name, and `state_url` makes it
  clickable. There is no channel URL to point at: only a subscription persists
  one, and the lists a video is usually played from — bookmarks, queue,
  history — keep the channel *name* and nothing else. So the link is a YouTube
  search for that name, the keyless tier cliamp-plugin's artist link falls
  back to. It needs no id, no request, and no new column, and it therefore
  works on every play path rather than on the ones that happen to carry a URL.

  It is built from the raw name rather than from the truncated `state` text,
  so the ellipsis a long name displays never becomes part of what is searched
  for. The name is cut to fit the documented 256-character limit on
  `state_url` — read from the docs rather than measured, and applied
  defensively: like an over-long text field, an over-long URL is a rejection
  of the whole activity rather than a harmless truncation. The cut runs
  codepoint by codepoint and re-encodes each piece, because slicing the
  *encoded* string can land inside a `%E6` escape and leave a URL nothing can
  parse.

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

  # Discord's own ceiling for every text field on the card, in the unit it
  # actually counts. One cap for all three: the title, the channel, and the
  # hover are the same strings shown in different places, and inventing a
  # tighter cap for one of them only means showing less of the same thing.
  @text_max_units 128

  @ellipsis "…"

  @thumbnail "https://i.ytimg.com/vi/~s/mqdefault.jpg"

  @watch_label "Watch on YouTube"

  # The channel link: no channel URL exists on the play path, so the card points
  # at a search for the channel name instead (see the moduledoc).
  @search_route "https://www.youtube.com/results?search_query="

  # Discord's documented cap on `details_url`/`state_url`. `details_url` is
  # always a bare video URL and cannot reach it; this one can, because a name
  # costs up to nine characters per codepoint once percent-encoded.
  @url_max_chars 256

  # Precomputed because the route is pure ASCII, so bytes and characters agree.
  @query_max_chars @url_max_chars - byte_size(@search_route)

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
      "details" => truncate_units(title, @text_max_units)
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
    activity
    |> Map.put("state", truncate_units(author, @text_max_units))
    |> Map.put("state_url", search_url(author))
  end

  defp put_state(activity, _card), do: activity

  defp search_url(name), do: @search_route <> search_query(name, @query_max_chars)

  # Encodes `name` one codepoint at a time, keeping whole pieces until the
  # budget runs out. Encoding the whole name and then cutting the result would
  # be the same URL right up until it wasn't: a cut through a multi-byte
  # escape leaves something `URI.decode_query/1` raises on, and Discord would
  # refuse the entire activity rather than the one field.
  defp search_query(name, budget) do
    name
    |> String.to_charlist()
    |> Enum.reduce_while({[], 0}, fn codepoint, {pieces, used} ->
      encoded = URI.encode_www_form(<<codepoint::utf8>>)
      size = byte_size(encoded)

      if used + size <= budget,
        do: {:cont, {[encoded | pieces], used + size}},
        else: {:halt, {pieces, used}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

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
      "large_text" => truncate_units(title, @text_max_units)
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

  # Cuts `text` to Discord's limit, marking the cut with an ellipsis. The
  # ellipsis is budgeted for, so a truncated field is never itself over-long.
  defp truncate_units(text, max) do
    if units(text) > max do
      take_units(text, max - units(@ellipsis)) <> @ellipsis
    else
      text
    end
  end

  # What Discord counts: one unit per codepoint, two for anything outside the
  # Basic Multilingual Plane. Counting runes would undercount every emoji by
  # half; counting bytes would overcount every non-ASCII character.
  defp units(text) do
    text |> String.to_charlist() |> Enum.reduce(0, &(unit_size(&1) + &2))
  end

  # Walks codepoints rather than runes so a cut can never land inside a
  # surrogate pair — half a codepoint is malformed, and Discord would reject
  # the activity for that alone.
  defp take_units(text, budget) do
    text
    |> String.to_charlist()
    |> Enum.reduce_while({[], budget}, fn codepoint, {acc, left} ->
      size = unit_size(codepoint)

      if size <= left do
        {:cont, {[codepoint | acc], left - size}}
      else
        {:halt, {acc, left}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> List.to_string()
  end

  defp unit_size(codepoint) when codepoint > 0xFFFF, do: 2
  defp unit_size(_codepoint), do: 1
end
