defmodule Playmark.Player.Vlc do
  @moduledoc """
  The VLC playback backend.

  VLC can't fetch YouTube pages, so unlike mpv this backend does the `yt-dlp`
  work itself before launching the player:

    1. resolve the raw stream URL(s) with `yt-dlp -g` (a split video+audio
       rendition comes back as two URLs, recombined via `--input-slave`);
    2. when captions are enabled, download the subtitle track (via
       `Playmark.Player.Captions`) and hand it to VLC as `--sub-file=`;
    3. play, then delete the temp subtitle file.

  Captions are best-effort: a video with no matching subtitle track just plays
  without one — never an error. `Playmark.Player.Mpv` uses the same download-and-
  sidecar mechanism; only the stream path (yt-dlp inside mpv vs. `-g` here)
  differs between the two.

  ## Player client (why `web_safari`)

  YouTube binds most signed stream URLs to the client that requested them, so a
  plain HTTP client like VLC gets `HTTP 403` and the player exits immediately.
  The `web_safari` client hands back an HLS URL a plain HTTP client can fetch;
  we force it on the `yt-dlp -g` call via `--extractor-args`. (Captions use a
  different client — see `Playmark.Player.Captions`.)

  ## Demuxer (why streams are opened as `https/avformat://…`)

  Those HLS segments still `403` intermittently, and VLC's own `adaptive` demuxer
  probes the *first* segment to determine the container format — so one failed
  segment aborts the whole input rather than being skipped. That is the second
  "opens then closes", distinguishable by `Failed to create demuxer (nil)
  Unknown` in VLC's log. ffmpeg's demuxer retries and skips, so `play/2` forces it
  (see `demux_mrl/2`). The demuxer is named in the MRL rather than passed as
  `--demux=avformat`, because that flag is global and also captured the caption
  sidecar — which broke playback outright with "Unidentified codec". Streams only;
  local files are left alone.

  Local files need no `yt-dlp`; VLC auto-loads a sidecar `.srt`/`.vtt` next to the
  file, so `play_local/2` just plays the path fullscreen.
  """

  @behaviour Playmark.Player

  alias Playmark.Player.{Captions, Control}
  alias Playmark.Player.Playback

  # Bounds each yt-dlp socket read/connect so a black-holed network can't hang
  # stream resolution forever (matching Playmark.Source.Channel). On timeout yt-dlp
  # errors and play/2 returns {:error, _} rather than blocking indefinitely.
  # User-overridable via the :socket_timeout config key (see Playmark.Config).
  @default_socket_timeout 30

  @impl true
  def executable, do: "vlc"

  @impl true
  def play(url, opts) when is_binary(url) do
    Playback.report(opts, :resolving)

    with {:ok, urls} <- resolve_streams(url, opts) do
      # Tell the UI what the resolution produced: a split video+audio pair
      # (recombined via --input-slave) or a single muxed stream. Best-effort,
      # like the caption report.
      Playback.report(opts, {:stream, stream_shape(urls)})

      sub_file =
        if opts.subtitles? do
          Playback.report(opts, :captions)
          Captions.download(url, opts)
        end

      try do
        Playback.report(opts, :playing)
        # A resolved YouTube stream is HLS, so force ffmpeg's demuxer — VLC's own
        # aborts the input when the first segment 403s. See demux_args/1.
        launch(urls, sub_file, Map.put(opts, :force_demux, "avformat"))
      after
        Captions.cleanup(sub_file)
      end
    end
  end

  @impl true
  def play_local(path, opts) when is_binary(path) do
    Playback.report(opts, :playing)
    launch([path], nil, opts)
  end

  @doc """
  Extracts playable stream URLs from `yt-dlp -g` output, in order.

  yt-dlp writes warnings (e.g. version notices) to stderr, which we merge into
  stdout; we keep only the lines that are actually URLs. For a split rendition
  the first URL is video and the second is audio; for a muxed rendition there is
  a single URL.
  """
  def parse_stream_urls(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "http"))
  end

  # --- stream resolution ---------------------------------------------------

  # The resolved rendition's shape, mirroring vlc_args/1: two URLs mean a split
  # video+audio pair, one means a single muxed stream.
  defp stream_shape([_video, _audio | _]), do: :split
  defp stream_shape([_muxed]), do: :muxed

  defp resolve_streams(url, opts) do
    args = [
      "--socket-timeout",
      socket_timeout(),
      "--extractor-args",
      "youtube:player_client=#{opts.player_client}",
      "-f",
      opts.format,
      "-g",
      url
    ]

    case System.cmd("yt-dlp", args, stderr_to_stdout: true) do
      {output, 0} ->
        case parse_stream_urls(output) do
          [] -> {:error, "yt-dlp returned no stream URL"}
          urls -> {:ok, urls}
        end

      {output, code} ->
        {:error, "yt-dlp failed (exit #{code}): #{String.trim(output)}"}
    end
  end

  # --- launch --------------------------------------------------------------

  defp launch(urls, sub_file, opts) do
    Control.run(
      :vlc,
      executable(),
      fn port -> launch_args(urls, sub_file, Map.put(opts, :control_port, port)) end,
      opts
    )
  end

  @doc """
  The VLC argument list for `urls` (one muxed URL, or video + audio) plus an
  optional subtitle `sub_file`, under `opts`. Exposed for testing so the
  constructed flags can be asserted without launching VLC.
  """
  def launch_args(urls, sub_file, opts) do
    vlc_args(urls, opts) ++ sub_args(sub_file) ++ meta_args(opts)
  end

  # Single muxed stream, or a split rendition with audio attached as a slave.
  # Both carry the forced demuxer on their own MRL: the audio slave is HLS too,
  # so it needs the same segment tolerance as the video.
  defp vlc_args([video], opts), do: base_args(opts) ++ [demux_mrl(video, opts)]

  defp vlc_args([video, audio | _], opts),
    do: base_args(opts) ++ [demux_mrl(video, opts), "--input-slave=#{demux_mrl(audio, opts)}"]

  defp base_args(opts) do
    ["-f", "--no-video-title-show", "--play-and-exit"] ++
      control_args(opts) ++ resume_args(opts)
  end

  # VLC's own `adaptive` demuxer probes the *first* HLS segment to determine the
  # container format, so a single failed segment aborts the whole input — that is
  # the "opens then closes" with `Failed to create demuxer (nil) Unknown`, and it
  # is exactly where YouTube's intermittent 403s land. ffmpeg's demuxer retries
  # and skips instead, which is the only reason mpv survives streams VLC does not.
  #
  # Measured against a local HLS stream with chosen segments forced to 403:
  # segment 0 failing killed `adaptive` and played fine under `avformat`; a
  # mid-stream failure was survivable either way; `--adaptive-use-access` did not
  # help.
  #
  # The demuxer rides on the MRL (`https/avformat://host/path`) rather than the
  # `--demux=avformat` flag this first used, because that flag is global in the
  # literal sense — VLC applied it to the `--sub-file` sidecar as well. It opened
  # the `.vtt` with avformat instead of its native `webvtt` demuxer, produced an
  # SPU stream nothing could decode, and failed the play outright:
  #
  #     main decoder debug: no spu decoder modules matched
  #     main decoder error: Unidentified codec
  #
  # So captions and this fix were mutually exclusive until the scope shrank to one
  # MRL. Verified against VLC 3.0.23: with the MRL form the stream still gets
  # `avformat` while the sidecar goes back to `webvtt`. Item-scoped `:demux=`
  # after the input does *not* work — the slave belongs to that same input item
  # and inherits it. (An earlier note here claimed `--sub-file` kept working under
  # the global flag; it was never exercised with a real sidecar.)
  #
  # Applied only on the streaming path (see `play/2`), never for local files:
  # forcing ffmpeg's demuxer on every container VLC handles natively is a broader
  # change than this problem needs.
  defp demux_mrl(url, %{force_demux: demux}) when is_binary(demux) do
    case String.split(url, "://", parts: 2) do
      [access, rest] -> "#{access}/#{demux}://#{rest}"
      _ -> url
    end
  end

  defp demux_mrl(url, _opts), do: url

  defp control_args(%{control_port: port}) when is_integer(port) and port > 0 do
    ["--no-one-instance", "--extraintf=rc", "--rc-host=127.0.0.1:#{port}"]
  end

  defp control_args(_opts), do: []

  defp resume_args(%{start_position_ms: position}) when is_integer(position) and position > 0,
    do: ["--start-time=#{seconds(position)}"]

  defp resume_args(_opts), do: []

  defp seconds(milliseconds) do
    if rem(milliseconds, 1_000) == 0 do
      to_string(div(milliseconds, 1_000))
    else
      :erlang.float_to_binary(milliseconds / 1_000, decimals: 3)
    end
  end

  defp sub_args(nil), do: []
  defp sub_args(sub_file), do: ["--sub-file=#{sub_file}"]

  # A pre-resolved HLS stream carries no metadata, so VLC shows "unknown title /
  # unknown artist" (including in its MPRIS desktop-media entry) unless we set it.
  # --meta-title / --meta-artist scope to the played input; the channel becomes the
  # artist. Each flag is omitted when its value is unknown (nil/blank). Note this is
  # distinct from --no-video-title-show above, which only suppresses the transient
  # on-video filename overlay.
  defp meta_args(opts) do
    meta_arg("--meta-title", Map.get(opts, :title)) ++
      meta_arg("--meta-artist", Map.get(opts, :author))
  end

  defp meta_arg(_flag, value) when not is_binary(value), do: []

  defp meta_arg(flag, value) do
    case String.trim(value) do
      "" -> []
      trimmed -> ["#{flag}=#{trimmed}"]
    end
  end

  # yt-dlp socket timeout as a string arg (shared :socket_timeout key, default
  # @default_socket_timeout — see Playmark.Config and Playmark.Source.Channel).
  defp socket_timeout,
    do: to_string(Application.get_env(:playmark, :socket_timeout, @default_socket_timeout))
end
