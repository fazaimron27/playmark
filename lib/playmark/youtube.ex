defmodule Playmark.YouTube do
  @moduledoc """
  Lightweight validation of YouTube URLs.

  Adding a bookmark or subscription triggers a network round-trip (oEmbed) or a
  `yt-dlp` subprocess to resolve the title/channel name. A typo, a bare word, or
  a non-YouTube link would otherwise spin up that whole call and fail slowly with
  a low-level error, after the user already waited through the `:fetching` state.
  A cheap upfront check turns those cases into an instant, clear rejection.

  This is deliberately permissive: it confirms the string is an `http(s)` URL on
  a YouTube host, not that it points at a real video or channel — only YouTube
  can say that. Being stricter (parsing every valid watch/channel URL shape)
  would risk rejecting legitimate links, which is worse than the slow failure it
  replaces.
  """

  # The hosts YouTube serves watch pages and channels from. `youtu.be` is the
  # short-link host; the `music.`/`m.` subdomains appear on shared links.
  @hosts ~w(youtube.com www.youtube.com m.youtube.com music.youtube.com youtu.be)

  @doc """
  Validates that `url` is an `http(s)` URL on a YouTube host.

  Returns `{:ok, url}` (unchanged, so callers can pipe it through a `with`) or
  `{:error, reason}` with a short, user-facing message.
  """
  def validate(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        if String.downcase(host) in @hosts,
          do: {:ok, url},
          else: {:error, "not a YouTube URL"}

      _ ->
        {:error, "not a YouTube URL — paste a full https:// link"}
    end
  end
end
