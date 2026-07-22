defmodule Playmark.Channel do
  @moduledoc """
  Reads a YouTube channel's video index with `yt-dlp`, without downloading
  anything and without an API key.

  `--flat-playlist` makes yt-dlp read the channel's listing page only — it emits
  one line per video (id and title) rather than resolving each video, so it
  returns in about a second. We derive a plain `watch?v=<id>` URL per video,
  which the existing playback path already knows how to handle.

  This mirrors `Playmark.Playback`: shell out to `yt-dlp`, parse its line-oriented
  output, return a tagged tuple.

  ## Title language

  For channels that publish multi-language titles, `yt-dlp --flat-playlist`
  returns the title in YouTube's default locale (often English), while the
  oEmbed endpoint `Playmark.Bookmarks` uses returns the *original* title. To keep
  the video list consistent with what bookmarking saves, we enrich each flat
  title with its oEmbed title (fetched in parallel), falling back to the flat
  title if oEmbed is unavailable for a given video.
  """

  alias Playmark.{Cache, Metadata, YouTube}

  # ASCII Unit Separator (0x1F): a control char that won't appear in a video
  # title, so we can reliably split id from title even when the title contains
  # pipes, tabs, or other punctuation.
  @sep ""

  # Defaults, overridable by the user via Playmark.Config. oEmbed enrichment is
  # fast in parallel (~0.2s for 10), but capped so one slow or hanging request
  # can't stall the whole list. @default_limit caps how many videos are fetched.
  @default_limit 30
  @default_oembed_timeout_ms 4_000
  @default_oembed_concurrency 10

  # Bounds each yt-dlp socket read/connect so a black-holed network can't hang a
  # listing forever. The TUI's Esc only drops the *result* (a mode guard) — the
  # underlying process keeps running — so the timeout is what actually frees it.
  # User-overridable via the :socket_timeout config key (see Playmark.Config).
  @default_socket_timeout 30

  @doc """
  Fetches a channel's display name, for storing alongside the subscription.

  Returns `{:ok, name}` or `{:error, reason}`.
  """
  def name(url) when is_binary(url) do
    # For a channel listing, the channel name lives in the playlist-level
    # `playlist_uploader` field; the video-level `channel`/`uploader` fields are
    # "NA" under --flat-playlist. --playlist-items 1 reads just one entry so this
    # stays fast.
    args = [
      "--socket-timeout",
      socket_timeout(),
      "--playlist-items",
      "1",
      "--flat-playlist",
      "--print",
      "%(playlist_uploader)s",
      url
    ]

    case System.cmd("yt-dlp", args, stderr_to_stdout: true) do
      {output, 0} ->
        case first_nonempty_line(output) do
          nil -> {:error, "could not read channel name"}
          "NA" -> {:error, "could not read channel name"}
          name -> {:ok, name}
        end

      {output, code} ->
        {:error, "yt-dlp failed (exit #{code}): #{String.trim(output)}"}
    end
  end

  @doc """
  Lists a channel's most recent videos, newest first.

  Returns `{:ok, [%{id, title, url, live}]}` or `{:error, reason}`. `tab` selects
  the channel page to read — `:videos` (the default, uploads) or `:streams`
  (live/past/upcoming broadcasts) — and is appended to the canonical channel URL,
  so a subscription's bare URL fetches either tab deterministically. The number
  of videos fetched is capped by the user's `:channel_limit` (or #{@default_limit}).
  Each video's `:live` is one of `:live`, `:ended`, `:upcoming`, or `:none` (see
  `parse_videos/1`).
  """
  def list_videos(url, tab \\ :videos)
      when is_binary(url) and tab in [:videos, :streams] do
    args = [
      "--socket-timeout",
      socket_timeout(),
      "--playlist-end",
      Integer.to_string(limit()),
      "--flat-playlist",
      "--print",
      "%(id)s#{@sep}%(title)s#{@sep}%(live_status)s",
      tab_url(url, tab)
    ]

    case System.cmd("yt-dlp", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output |> parse_videos() |> enrich_titles()}
      {output, code} -> {:error, "yt-dlp failed (exit #{code}): #{String.trim(output)}"}
    end
  end

  # Appends the tab segment to a channel URL. A subscription URL is normally
  # stored bare (its tab stripped on add — see
  # Playmark.YouTube.canonical_channel_url/1), but we canonicalize here too so a
  # legacy stored URL that still carries `/videos` doesn't become `/videos/streams`.
  defp tab_url(url, tab) do
    url
    |> YouTube.canonical_channel_url()
    |> String.trim_trailing("/")
    |> Kernel.<>("/" <> Atom.to_string(tab))
  end

  @doc """
  Replaces each flat-playlist title with its oEmbed title (the original-language
  one, matching what bookmarking stores) and attaches the channel name as
  `:author`.

  Both fields come from the same oEmbed lookup. Values seen before are served
  from `Playmark.Cache` (a video's title/author are effectively immutable), so
  only videos missing from the cache trigger an oEmbed request. Those requests
  run in parallel; any video whose lookup fails or times out keeps its flat title
  (and a `nil` author), so a flaky request never drops a video from the list. A
  failed lookup is not cached. Order is preserved.

  The `:author` feeds the player's artist metadata (see `Playmark.Player.Vlc`);
  a `nil` author simply means no artist flag is set.
  """
  def enrich_titles([]), do: []

  def enrich_titles(videos) do
    # Classify each video with a single title lookup, keeping the looked-up value
    # so a hit needs no second read. A hit carries its cached title; a miss still
    # needs an oEmbed request. (The author lives under its own key, read only for
    # the hits that reached this list — a miss's author comes from oEmbed.)
    {hits, misses} =
      videos
      |> Enum.map(fn video -> {video, Cache.get({:title, video.id})} end)
      |> Enum.split_with(fn {_video, title} -> match?({:ok, _}, title) end)

    resolved =
      Map.new(hits, fn {video, {:ok, title}} ->
        {video.id, {title, cached(:author, video.id, nil)}}
      end)

    resolved =
      misses
      |> Enum.map(fn {video, _miss} -> video end)
      |> fetch_titles()
      |> Enum.reduce(resolved, fn video, acc ->
        Map.put(acc, video.id, {video.title, video.author})
      end)

    # Reassemble in the original order, swapping in each resolved title/author.
    Enum.map(videos, fn video ->
      {title, author} = Map.fetch!(resolved, video.id)
      video |> Map.put(:title, title) |> Map.put(:author, author)
    end)
  end

  # The cached value for a namespaced key, or the fallback if the entry vanished
  # since the hit/miss split.
  defp cached(namespace, id, fallback) do
    case Cache.get({namespace, id}) do
      {:ok, value} -> value
      :miss -> fallback
    end
  end

  # Fetches oEmbed titles + authors for the given videos in parallel, caching each
  # success. Returns the videos with `:title` replaced and `:author` set (flat
  # title kept and `:author` nil on failure).
  defp fetch_titles([]), do: []

  defp fetch_titles(videos) do
    metadata = metadata()

    videos
    |> Task.async_stream(
      fn video ->
        case metadata.fetch(video.url) do
          {:ok, %{title: title, channel: channel}} ->
            Cache.put({:title, video.id}, title)
            Cache.put({:author, video.id}, channel)
            video |> Map.put(:title, title) |> Map.put(:author, channel)

          {:error, _reason} ->
            Map.put(video, :author, nil)
        end
      end,
      max_concurrency: oembed_concurrency(),
      timeout: oembed_timeout_ms(),
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(videos)
    |> Enum.map(fn
      {{:ok, enriched}, _original} -> enriched
      {{:exit, _reason}, original} -> Map.put(original, :author, nil)
    end)
  end

  @doc """
  Parses `yt-dlp --print "%(id)s<sep>%(title)s<sep>%(live_status)s"` output into
  video maps.

  yt-dlp may interleave warnings (e.g. version notices); we keep only lines that
  carry the id/title separator, so warnings are dropped. The third field is
  yt-dlp's `live_status`, normalized to a `:live` tag on each map: `:live`
  (currently broadcasting), `:ended` (a finished broadcast), `:upcoming`
  (scheduled), or `:none` (a regular upload, or the field absent). A line with
  only two fields — from an older template or a source that omits the field —
  still parses, defaulting `:live` to `:none`, so Search and any cached call site
  keep working.
  """
  def parse_videos(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.contains?(&1, @sep))
    |> Enum.map(fn line ->
      {id, title, status} =
        case String.split(line, @sep, parts: 3) do
          [id, title, status] -> {id, title, status}
          [id, title] -> {id, title, nil}
        end

      %{
        id: id,
        title: title,
        url: "https://www.youtube.com/watch?v=#{id}",
        live: live_status(status)
      }
    end)
  end

  # Normalizes yt-dlp's `live_status` string to the tag the view badges on.
  # "is_live" is a running broadcast; "was_live"/"post_live" are finished ones
  # ("post_live" is the brief window just after a stream ends, before the VOD is
  # processed); "is_upcoming" is scheduled. Everything else — "not_live", "NA",
  # nil — is an ordinary video with no badge.
  defp live_status("is_live"), do: :live
  defp live_status("was_live"), do: :ended
  defp live_status("post_live"), do: :ended
  defp live_status("is_upcoming"), do: :upcoming
  defp live_status(_other), do: :none

  defp first_nonempty_line(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != "" and not String.starts_with?(&1, "WARNING")))
  end

  # Seam so tests can enrich titles without hitting the oEmbed endpoint, matching
  # the :playback_impl / :channel_impl seams used elsewhere.
  defp metadata, do: Application.get_env(:playmark, :metadata_impl, Metadata)

  # User-overridable settings (see Playmark.Config), each falling back to the
  # built-in default when unset.
  defp limit, do: Application.get_env(:playmark, :channel_limit, @default_limit)

  defp oembed_timeout_ms,
    do: Application.get_env(:playmark, :oembed_timeout_ms, @default_oembed_timeout_ms)

  defp oembed_concurrency,
    do: Application.get_env(:playmark, :oembed_concurrency, @default_oembed_concurrency)

  # yt-dlp wants the socket timeout as a string arg; the config value is an
  # integer (seconds), so render it here.
  defp socket_timeout,
    do:
      Integer.to_string(Application.get_env(:playmark, :socket_timeout, @default_socket_timeout))
end
