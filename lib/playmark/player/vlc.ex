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

  Local files need no `yt-dlp`; VLC auto-loads a sidecar `.srt`/`.vtt` next to the
  file, so `play_local/2` just plays the path fullscreen.
  """

  @behaviour Playmark.Player

  alias Playmark.Player.Captions
  alias Playmark.Playback

  # Bounds each yt-dlp socket read/connect so a black-holed network can't hang
  # stream resolution forever (matching Playmark.Channel). On timeout yt-dlp
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
        launch(urls, sub_file, opts)
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
    Playback.run(executable(), launch_args(urls, sub_file, opts))
  end

  @doc """
  The VLC argument list for `urls` (one muxed URL, or video + audio) plus an
  optional subtitle `sub_file`, under `opts`. Exposed for testing so the
  constructed flags can be asserted without launching VLC.
  """
  def launch_args(urls, sub_file, opts) do
    vlc_args(urls) ++ sub_args(sub_file) ++ meta_args(opts)
  end

  # Single muxed stream, or a split rendition with audio attached as a slave.
  defp vlc_args([video]), do: base_args() ++ [video]
  defp vlc_args([video, audio | _]), do: base_args() ++ [video, "--input-slave=#{audio}"]

  defp base_args, do: ["-f", "--no-video-title-show", "--play-and-exit"]

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
  # @default_socket_timeout — see Playmark.Config and Playmark.Channel).
  defp socket_timeout,
    do: to_string(Application.get_env(:playmark, :socket_timeout, @default_socket_timeout))
end
