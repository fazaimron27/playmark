defmodule Playmark.Player.Ffplay do
  @moduledoc """
  The ffplay playback backend — a minimal, no-extra-install tier.

  ffplay ships with FFmpeg, which `yt-dlp` already depends on, so it is almost
  always present with no separate install. It fills the niche neither `mpv`
  (scriptable) nor `vlc` (GUI-rich) does: a lightweight fallback player.

  Like VLC, ffplay can't fetch YouTube pages, so this backend pre-resolves the
  stream with `yt-dlp -g` (forcing the `web_safari` client, whose URLs a plain
  HTTP client can actually fetch). Two things it deliberately does *not* do,
  because ffplay's CLI can't:

    * **Split video+audio.** ffplay has no `--input-slave` equivalent, so it
      can't recombine a split rendition. We force a *single muxed* format
      (`best[height<=N]`) so `yt-dlp -g` returns exactly one URL.
    * **Captions.** ffplay has no clean `--sub-file` sidecar; burning a track in
      via a filter is finicky. So this backend skips captions entirely — a video
      just plays without them. (`opts.subtitles?` and the `subtitle_*` fields are
      accepted but ignored.)

  Metadata: ffplay has no title/artist flags like mpv's `--force-media-title` or
  VLC's `--meta-*`. It accepts `-window_title`, so the OS window title is set to
  the video title; there is no artist concept, so `opts.author` is ignored (as
  mpv also ignores it).

  Local files need no `yt-dlp`; `play_local/2` hands the path directly to ffplay.
  playmark does not attach a caption sidecar for this backend.
  """

  @behaviour Playmark.Player

  alias Playmark.Playback

  # Bounds each yt-dlp socket read/connect so a black-holed network can't hang
  # stream resolution forever (matching Playmark.Player.Vlc / Playmark.Source.Channel).
  # User-overridable via the :socket_timeout config key (see Playmark.Config).
  @default_socket_timeout 30

  @impl true
  def executable, do: "ffplay"

  @impl true
  def play(url, opts) when is_binary(url) do
    Playback.report(opts, :resolving)

    with {:ok, stream_url} <- resolve_stream(url, opts) do
      Playback.report(opts, {:stream, :muxed})
      Playback.report(opts, :playing)
      Playback.run(executable(), play_args(stream_url, opts))
    end
  end

  @impl true
  def play_local(path, opts) when is_binary(path) do
    Playback.report(opts, :playing)
    Playback.run(executable(), play_args(path, opts))
  end

  @doc """
  The ffplay argument list for `url` (a pre-resolved stream URL or a local path)
  under `opts`. Exposed for testing so the constructed flags can be asserted
  without launching ffplay.

  `-fs` plays fullscreen, `-autoexit` quits at end of stream (VLC's
  `--play-and-exit` analogue). `-window_title` sets the OS window title to the
  display title, omitted when no title is known (nil/blank).
  """
  def play_args(url, opts) do
    ["-fs", "-autoexit"] ++ title_args(opts) ++ [url]
  end

  # A pre-resolved stream carries no title metadata, so set the window title
  # explicitly. Omitted when no title is known (nil/blank) so ffplay keeps its
  # own default. mirrors the trim guard in Playmark.Player.Vlc.meta_arg/2.
  defp title_args(%{title: title}) when is_binary(title) do
    case String.trim(title) do
      "" -> []
      trimmed -> ["-window_title", trimmed]
    end
  end

  defp title_args(_opts), do: []

  # --- stream resolution ---------------------------------------------------

  # Resolve a single muxed stream URL. ffplay can't recombine split streams, so
  # force a muxed selector (best[height<=N]) rather than opts.format (which is
  # bestvideo+bestaudio/best and would return two URLs). Take the first URL.
  defp resolve_stream(url, opts) do
    args = [
      "--socket-timeout",
      socket_timeout(),
      "--extractor-args",
      "youtube:player_client=#{opts.player_client}",
      "-f",
      muxed_format(),
      "-g",
      url
    ]

    case System.cmd("yt-dlp", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Playback.parse_stream_urls(output) do
          [] -> {:error, "yt-dlp returned no stream URL"}
          [stream_url | _] -> {:ok, stream_url}
        end

      {output, code} ->
        {:error, "yt-dlp failed (exit #{code}): #{String.trim(output)}"}
    end
  end

  # A single muxed rendition capped at the configured max height (ffplay can't
  # combine separate video+audio streams).
  defp muxed_format, do: "best[height<=#{Playback.max_height()}]"

  # yt-dlp socket timeout as a string arg (shared :socket_timeout key, default
  # @default_socket_timeout — see Playmark.Config and Playmark.Player.Vlc).
  defp socket_timeout,
    do: to_string(Application.get_env(:playmark, :socket_timeout, @default_socket_timeout))
end
