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

  # A YouTube video id is exactly 11 characters of this alphabet. Checking the
  # shape rather than trusting the presence of a `v` parameter is what keeps a
  # truncated or hand-edited URL from reaching Discord as a broken image link.
  @video_id ~r/^[A-Za-z0-9_-]{11}$/

  # The channel-page tab segments YouTube appends to a channel URL (Videos,
  # Streams, Shorts, etc.). We strip a trailing one so a subscription stores the
  # canonical bare channel URL, and the app decides which tab to fetch.
  @channel_tabs ~w(videos streams shorts featured live playlists community)

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

  @doc """
  Strips a trailing channel-tab segment (`/videos`, `/streams`, `/shorts`, …)
  from a channel URL, returning the canonical bare channel URL.

  A channel page has separate tabs (Videos, Streams, …) that yt-dlp treats as
  distinct playlists; pasting `.../@handle/videos` would otherwise be stored and
  re-fetched as that exact tab forever, differing from `.../@handle`. Normalizing
  on add lets the app hold one canonical URL and choose the tab itself (see
  `Playmark.Source.Channel.list_videos/2`).

  Deliberately conservative: only a known tab word as the *final* path segment is
  removed (with any trailing slash). Watch links (`watch?v=`, `youtu.be/ID`) and
  already-bare channel URLs pass through unchanged, and the host is never
  rewritten. Non-string or unparseable input is returned as-is for the caller's
  validation to reject.
  """
  def canonical_channel_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{path: path} = uri when is_binary(path) ->
        stripped = strip_tab_segment(path)
        uri |> Map.put(:path, stripped) |> URI.to_string()

      _ ->
        url
    end
  end

  def canonical_channel_url(url), do: url

  @doc """
  Returns the canonical URL for a YouTube playlist identified by the `list`
  query parameter.

  Direct playlist URLs and watch/share URLs carrying `list=` normalize to the
  same URL, so saving equivalent links cannot create duplicate records.
  """
  def canonical_playlist_url(url) when is_binary(url) do
    url = String.trim(url)

    with {:ok, _url} <- validate(url),
         %URI{query: query} when is_binary(query) <- URI.parse(url),
         {:ok, params} <- decode_query(query),
         id when is_binary(id) <- Map.get(params, "list"),
         id when id != "" <- String.trim(id) do
      {:ok, "https://www.youtube.com/playlist?" <> URI.encode_query(%{"list" => id})}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "not a YouTube playlist URL"}
    end
  end

  def canonical_playlist_url(_url), do: {:error, "not a YouTube playlist URL"}

  @doc """
  Extracts the video id from a YouTube watch URL or `youtu.be` short link.

  Returns `nil` for anything else — a channel, a playlist, another host, a
  local path, junk, or a non-binary. Callers use `nil` as "there is no id",
  which is a legal state everywhere it is consumed (the presence card simply
  omits its thumbnail).

  Pure: no network, no IO. The id is derived from the URL playmark already
  holds, so a thumbnail costs no request.
  """
  def video_id(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host, path: path, query: query} when is_binary(host) ->
        case String.downcase(host) do
          "youtu.be" -> path |> first_segment()
          host when host in @hosts -> if path == "/watch", do: from_query(query), else: nil
          _other -> nil
        end

      _other ->
        nil
    end
  end

  def video_id(_url), do: nil

  # A short link's id is its first non-empty path segment, so a trailing slash
  # or a fragment does not change the answer.
  defp first_segment(path) when is_binary(path) do
    path |> String.split("/", trim: true) |> List.first() |> clean_id()
  end

  defp first_segment(_path), do: nil

  defp from_query(query) when is_binary(query) do
    case URI.decode_query(query) do
      %{"v" => value} -> clean_id(value)
      _other -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp from_query(_query), do: nil

  defp clean_id(value) when is_binary(value) do
    value = String.trim(value)
    if Regex.match?(@video_id, value), do: value, else: nil
  end

  defp clean_id(_value), do: nil

  # Drops a trailing "/<tab>" (or "/<tab>/") when <tab> is a known channel tab,
  # preserving the rest of the path. A path without a trailing tab is returned
  # unchanged.
  defp strip_tab_segment(path) do
    segments = String.split(path, "/", trim: true)

    case Enum.reverse(segments) do
      [last | rest] when last in @channel_tabs ->
        case Enum.reverse(rest) do
          [] -> "/"
          kept -> "/" <> Enum.join(kept, "/")
        end

      _ ->
        path
    end
  end

  defp decode_query(query) do
    {:ok, URI.decode_query(query)}
  rescue
    ArgumentError -> {:error, "not a YouTube playlist URL"}
  end
end
