defmodule Playmark.Player.VlcTest do
  use ExUnit.Case, async: true

  alias Playmark.Player.Vlc

  @opts %{title: "Some Video Title", author: "Some Channel"}

  describe "launch_args/3" do
    test "single muxed stream plays directly, no slave input" do
      args = Vlc.launch_args(["https://example.com/muxed"], nil, @opts)

      assert args == [
               "-f",
               "--no-video-title-show",
               "--play-and-exit",
               "https://example.com/muxed",
               "--meta-title=Some Video Title",
               "--meta-artist=Some Channel"
             ]
    end

    test "split rendition attaches audio as a slave input" do
      args =
        Vlc.launch_args(["https://example.com/video", "https://example.com/audio"], nil, @opts)

      assert "https://example.com/video" in args
      assert "--input-slave=https://example.com/audio" in args
    end

    test "a subtitle file is passed via --sub-file" do
      args = Vlc.launch_args(["https://example.com/muxed"], "/tmp/subs.en.vtt", @opts)

      assert "--sub-file=/tmp/subs.en.vtt" in args
    end

    test "no subtitle file adds no --sub-file arg" do
      args = Vlc.launch_args(["https://example.com/muxed"], nil, @opts)

      refute Enum.any?(args, &String.starts_with?(&1, "--sub-file"))
    end

    test "sets the media title so VLC shows it, not \"unknown title\"" do
      args = Vlc.launch_args(["https://example.com/muxed"], nil, @opts)

      assert "--meta-title=Some Video Title" in args
    end

    test "sets the channel as artist so VLC shows it, not \"unknown artist\"" do
      args = Vlc.launch_args(["https://example.com/muxed"], nil, @opts)

      assert "--meta-artist=Some Channel" in args
    end

    test "omits the title flag when no title is known" do
      args = Vlc.launch_args(["https://example.com/muxed"], nil, %{title: nil})

      refute Enum.any?(args, &String.starts_with?(&1, "--meta-title"))
    end

    test "omits the title flag when the title is blank" do
      args = Vlc.launch_args(["https://example.com/muxed"], nil, %{title: "   "})

      refute Enum.any?(args, &String.starts_with?(&1, "--meta-title"))
    end

    test "omits the artist flag when no author is known" do
      args = Vlc.launch_args(["https://example.com/muxed"], nil, %{title: "T", author: nil})

      refute Enum.any?(args, &String.starts_with?(&1, "--meta-artist"))
    end

    test "omits the artist flag when the author is blank" do
      args = Vlc.launch_args(["https://example.com/muxed"], nil, %{title: "T", author: "   "})

      refute Enum.any?(args, &String.starts_with?(&1, "--meta-artist"))
    end

    test "omits the artist flag when the author key is absent" do
      args = Vlc.launch_args(["https://example.com/muxed"], nil, %{title: "T"})

      refute Enum.any?(args, &String.starts_with?(&1, "--meta-artist"))
    end

    # VLC's own `adaptive` demuxer aborts the whole input when the *first* HLS
    # segment fails to download, which is where YouTube's 403s land. Forcing
    # ffmpeg's demuxer makes it retry and skip instead — measured against a local
    # HLS stream with segment 0 returning 403: adaptive died, avformat played.
    #
    # It rides on the MRL rather than a global `--demux=` flag, because the flag
    # is global in the literal sense: VLC applied it to the subtitle sidecar too,
    # opening a .vtt with ffmpeg instead of its own `webvtt` demuxer and killing
    # playback with "Unidentified codec". See the sidecar test below.
    test "forces ffmpeg's demuxer when asked, scoped to the stream MRL" do
      opts = Map.put(@opts, :force_demux, "avformat")

      args = Vlc.launch_args(["https://example.com/muxed"], nil, opts)

      assert "https/avformat://example.com/muxed" in args
      refute "https://example.com/muxed" in args
      refute Enum.any?(args, &String.starts_with?(&1, "--demux="))
    end

    # The regression this scoping exists for: a global --demux=avformat leaked
    # onto the `--sub-file` slave, so VLC opened the .vtt with avformat, found no
    # spu decoder for what came out, and failed the whole play with "Unidentified
    # codec". Verified against VLC 3.0.23 — the sidecar must stay a plain path so
    # VLC picks its native `webvtt` demuxer.
    test "leaves the subtitle sidecar on its own demuxer" do
      opts = Map.put(@opts, :force_demux, "avformat")

      args = Vlc.launch_args(["https://example.com/muxed"], "/tmp/subs.vtt", opts)

      assert "--sub-file=/tmp/subs.vtt" in args
      refute Enum.any?(args, &String.starts_with?(&1, "--demux="))
    end

    # A split rendition plays audio as a slave input, which is HLS too and needs
    # the same tolerance — it would otherwise fall back to `adaptive`.
    test "scopes the demuxer onto the audio slave as well" do
      opts = Map.put(@opts, :force_demux, "avformat")

      args =
        Vlc.launch_args(
          ["https://example.com/video", "https://example.com/audio"],
          nil,
          opts
        )

      assert "https/avformat://example.com/video" in args
      assert "--input-slave=https/avformat://example.com/audio" in args
    end

    # Local files never hit the HLS path, and forcing ffmpeg's demuxer for every
    # container VLC handles natively is a bigger change than the problem needs.
    test "leaves the demuxer alone when not asked" do
      args = Vlc.launch_args(["/tmp/clip.mp4"], nil, @opts)

      refute Enum.any?(args, &String.starts_with?(&1, "--demux="))
      assert "/tmp/clip.mp4" in args
    end

    test "adds a dedicated RC socket and resume offset before the input" do
      opts =
        Map.merge(@opts, %{
          control_port: 42_199,
          start_position_ms: 90_500
        })

      args = Vlc.launch_args(["https://example.com/muxed"], nil, opts)

      assert "--no-one-instance" in args
      assert "--extraintf=rc" in args
      assert "--rc-host=127.0.0.1:42199" in args
      assert "--start-time=90.500" in args

      assert Enum.find_index(args, &(&1 == "--start-time=90.500")) <
               Enum.find_index(args, &(&1 == "https://example.com/muxed"))
    end
  end

  describe "parse_stream_urls/1" do
    test "keeps only http lines, in order" do
      output = "WARNING: something\nhttps://example.com/v\nhttps://example.com/a\n"

      assert Vlc.parse_stream_urls(output) ==
               ["https://example.com/v", "https://example.com/a"]
    end

    test "trims surrounding whitespace" do
      assert Vlc.parse_stream_urls("  https://example.com/s  \n") ==
               ["https://example.com/s"]
    end

    test "returns [] when there are no URLs" do
      assert Vlc.parse_stream_urls("WARNING: nothing here\n") == []
      assert Vlc.parse_stream_urls("") == []
    end
  end

  test "executable/0 is vlc" do
    assert Vlc.executable() == "vlc"
  end
end
