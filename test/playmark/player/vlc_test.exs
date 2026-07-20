defmodule Playmark.Player.VlcTest do
  use ExUnit.Case, async: true

  alias Playmark.Player.Vlc

  describe "launch_args/2" do
    test "single muxed stream plays directly, no slave input" do
      args = Vlc.launch_args(["https://example.com/muxed"], nil)

      assert args == [
               "-f",
               "--no-video-title-show",
               "--play-and-exit",
               "https://example.com/muxed"
             ]
    end

    test "split rendition attaches audio as a slave input" do
      args = Vlc.launch_args(["https://example.com/video", "https://example.com/audio"], nil)

      assert "https://example.com/video" in args
      assert "--input-slave=https://example.com/audio" in args
    end

    test "a subtitle file is passed via --sub-file" do
      args = Vlc.launch_args(["https://example.com/muxed"], "/tmp/subs.en.vtt")

      assert "--sub-file=/tmp/subs.en.vtt" in args
    end

    test "no subtitle file adds no --sub-file arg" do
      args = Vlc.launch_args(["https://example.com/muxed"], nil)

      refute Enum.any?(args, &String.starts_with?(&1, "--sub-file"))
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
