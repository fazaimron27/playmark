defmodule Playmark.Player.MpvTest do
  use ExUnit.Case, async: true

  alias Playmark.Player.Mpv

  @opts %{
    format: "bestvideo[height<=1080]+bestaudio/best",
    subtitles?: true,
    subtitle_default: "en",
    subtitle_fallback: nil,
    subtitle_translate: true,
    player_client: "web_safari",
    subtitle_client: "default",
    title: "Some Video Title"
  }

  describe "play_args/3" do
    test "plays fullscreen with the configured format and stream player client" do
      args = Mpv.play_args("https://youtu.be/x", nil, @opts)

      assert "--fs" in args
      assert "--ytdl-format=bestvideo[height<=1080]+bestaudio/best" in args
      assert List.last(args) == "https://youtu.be/x"

      raw = raw_options(args)
      assert raw =~ "extractor-args=youtube:player_client=web_safari"
    end

    test "does not put subtitle options in mpv's yt-dlp pass" do
      # Captions are fetched out-of-band with the caption client, because the
      # stream client (web_safari) discards them; nothing subtitle-related
      # belongs in mpv's own yt-dlp raw options.
      raw =
        "https://youtu.be/x" |> then(&Mpv.play_args(&1, "/tmp/s.en.vtt", @opts)) |> raw_options()

      refute raw =~ "sub-langs"
      refute raw =~ "write-subs"
      refute raw =~ "write-auto-subs"
    end

    test "attaches and force-selects a downloaded sidecar" do
      args = Mpv.play_args("https://youtu.be/x", "/tmp/s.en.vtt", @opts)

      # A downloaded track still has to be selected or mpv shows nothing.
      assert "--sub-file=/tmp/s.en.vtt" in args
      assert "--sid=1" in args
    end

    test "omits subtitle args when no sidecar was downloaded" do
      args = Mpv.play_args("https://youtu.be/x", nil, @opts)

      refute Enum.any?(args, &String.starts_with?(&1, "--sub-file"))
      refute "--sid=1" in args
      # The stream client is always forced, captions or not.
      assert raw_options(args) =~ "player_client=web_safari"
    end

    test "forces the media title so the player shows it, not \"unknown title\"" do
      args = Mpv.play_args("https://youtu.be/x", nil, @opts)

      assert "--force-media-title=Some Video Title" in args
    end

    test "omits the title flag when no title is known" do
      args = Mpv.play_args("https://youtu.be/x", nil, %{@opts | title: nil})

      refute Enum.any?(args, &String.starts_with?(&1, "--force-media-title"))
    end

    test "omits the title flag when the title is blank" do
      args = Mpv.play_args("https://youtu.be/x", nil, %{@opts | title: "   "})

      refute Enum.any?(args, &String.starts_with?(&1, "--force-media-title"))
    end

    test "adds the IPC socket and resume offset before the URL" do
      opts =
        Map.merge(@opts, %{control_socket: "/tmp/playmark-mpv.sock", start_position_ms: 90_500})

      args = Mpv.play_args("https://youtu.be/x", nil, opts)

      assert "--input-ipc-server=/tmp/playmark-mpv.sock" in args
      assert "--start=90.500" in args
      assert List.last(args) == "https://youtu.be/x"
    end
  end

  describe "local_args/2" do
    test "applies control and resume options to local files" do
      opts = %{
        title: "Local",
        control_socket: "/tmp/playmark-mpv.sock",
        start_position_ms: 120_000
      }

      args = Mpv.local_args("/videos/local.mp4", opts)

      assert "--input-ipc-server=/tmp/playmark-mpv.sock" in args
      assert "--start=120" in args
      assert List.last(args) == "/videos/local.mp4"
    end
  end

  test "executable/0 is mpv" do
    assert Mpv.executable() == "mpv"
  end

  defp raw_options(args) do
    Enum.find_value(args, fn
      "--ytdl-raw-options=" <> rest -> rest
      _ -> nil
    end)
  end
end
