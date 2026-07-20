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

  alias Playmark.{Cache, Metadata}

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

  Returns `{:ok, [%{id: String.t(), title: String.t(), url: String.t()}]}` or
  `{:error, reason}`. `limit` caps how many videos are fetched, defaulting to the
  user's `:channel_limit` (or #{@default_limit}).
  """
  def list_videos(url, limit \\ limit()) when is_binary(url) and is_integer(limit) do
    args = [
      "--playlist-end",
      Integer.to_string(limit),
      "--flat-playlist",
      "--print",
      "%(id)s#{@sep}%(title)s",
      url
    ]

    case System.cmd("yt-dlp", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output |> parse_videos() |> enrich_titles()}
      {output, code} -> {:error, "yt-dlp failed (exit #{code}): #{String.trim(output)}"}
    end
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
    # Read each id's cached title once, splitting hits (title + author resolved,
    # cached together) from misses (still need an oEmbed request).
    {hits, misses} =
      Enum.split_with(videos, fn video -> match?({:ok, _}, Cache.get({:title, video.id})) end)

    resolved =
      Map.new(hits, fn video ->
        {video.id, {cached(:title, video.id, video.title), cached(:author, video.id, nil)}}
      end)

    resolved =
      misses
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
  Parses `yt-dlp --print "%(id)s<sep>%(title)s"` output into video maps.

  yt-dlp may interleave warnings (e.g. version notices); we keep only lines that
  carry the id/title separator, so warnings are dropped.
  """
  def parse_videos(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.contains?(&1, @sep))
    |> Enum.map(fn line ->
      [id, title] = String.split(line, @sep, parts: 2)
      %{id: id, title: title, url: "https://www.youtube.com/watch?v=#{id}"}
    end)
  end

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
end
