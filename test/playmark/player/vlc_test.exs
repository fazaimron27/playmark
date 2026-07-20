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
