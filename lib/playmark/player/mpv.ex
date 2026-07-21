defmodule Playmark.Player.Mpv do
  @moduledoc """
  The mpv playback backend.

  mpv drives `yt-dlp` itself, so the YouTube URL is handed to mpv directly and the
  stream is steered through mpv's own `--ytdl-*` options: the format preference
  and the forced player client (`web_safari`, for a fetchable stream).

  Captions can't come from that same pass, though. `web_safari` discards caption
  tracks unless a PO token is supplied, so playmark downloads the track separately
  (with the caption client — see `Playmark.Player.Captions`) into a temp `.vtt` and
  hands it to mpv as a sidecar (`--sub-file`), auto-selecting it with `--sid` so it
  shows without the user pressing `v`. The temp file is deleted when mpv exits.

  Local files need no `yt-dlp` at all; mpv auto-loads a sidecar `.srt`/`.vtt`
  sitting next to the file, so `play_local/2` just plays the path fullscreen.
  """

  @behaviour Playmark.Player

  alias Playmark.Player.Captions
  alias Playmark.Playback

  @impl true
  def play(url, opts) when is_binary(url) do
    # mpv resolves the stream itself, so there's no separate :resolving stage
    # here (unlike VLC); captions are the only pre-launch step to report.
    sub_file =
      if opts.subtitles? do
        Playback.report(opts, :captions)
        Captions.download(url, opts)
      end

    try do
      Playback.report(opts, :playing)
      Playback.run(executable(), play_args(url, sub_file, opts))
    after
      Captions.cleanup(sub_file)
    end
  end

  @impl true
  def executable, do: "mpv"

  @impl true
  def play_local(path, opts) when is_binary(path) do
    Playback.report(opts, :playing)
    Playback.run(executable(), ["--fs"] ++ title_args(opts) ++ [path])
  end

  @doc """
  The mpv argument list for streaming `url` under `opts`, with an optional
  downloaded caption `sub_file`. Exposed for testing so the constructed flags can
  be asserted without launching mpv or downloading anything.
  """
  def play_args(url, sub_file, opts) do
    ["--fs", "--ytdl-format=#{opts.format}", "--ytdl-raw-options=#{ytdl_raw_options(opts)}"] ++
      title_args(opts) ++
      subtitle_args(sub_file) ++
      [url]
  end

  # A pre-resolved stream carries no title metadata, so mpv shows "unknown title"
  # unless we force one. Omitted when no title is known (nil/blank) so mpv keeps
  # whatever it can infer.
  defp title_args(%{title: title}) when is_binary(title) do
    case String.trim(title) do
      "" -> []
      trimmed -> ["--force-media-title=#{trimmed}"]
    end
  end

  defp title_args(_opts), do: []

  # A downloaded sidecar is loaded with --sub-file and force-selected with --sid=1
  # so it displays immediately (mpv won't auto-select an external sub otherwise).
  # No file (none available, or captions off) means no subtitle args at all.
  defp subtitle_args(nil), do: []
  defp subtitle_args(sub_file), do: ["--sub-file=#{sub_file}", "--sid=1"]

  # mpv passes --ytdl-raw-options as a single comma-separated list of yt-dlp
  # key=value pairs. We only force the stream player client here; captions are
  # fetched out-of-band (web_safari discards them), so no sub options belong in
  # this pass.
  defp ytdl_raw_options(opts) do
    "extractor-args=youtube:player_client=#{opts.player_client}"
  end
end
