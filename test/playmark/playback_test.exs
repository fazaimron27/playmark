defmodule Playmark.PlaybackTest do
  # Not async: several tests mutate the :playmark/:player application env.
  use ExUnit.Case, async: false

  alias Playmark.Playback

  describe "player/0 and executable/1" do
    test "falls back to mpv when nothing is configured" do
      # Assert on the built-in default, independent of whatever config.exs sets,
      # so this test doesn't break when the configured player is switched.
      original = Application.fetch_env(:playmark, :player)
      Application.delete_env(:playmark, :player)
      on_exit(fn -> restore_env(original) end)

      assert Playback.player() == :mpv
    end

    test "reads the configured player" do
      original = Application.fetch_env(:playmark, :player)
      Application.put_env(:playmark, :player, :vlc)
      on_exit(fn -> restore_env(original) end)

      assert Playback.player() == :vlc
    end

    test "maps players to their executables" do
      assert Playback.executable(:mpv) == "mpv"
      assert Playback.executable(:vlc) == "vlc"
      assert Playback.executable(:ffplay) == "ffplay"
    end
  end

  describe "resume_supported?/0" do
    test "supports mpv and VLC but not ffplay" do
      original = Application.fetch_env(:playmark, :player)
      on_exit(fn -> restore_env(original) end)

      Application.put_env(:playmark, :player, :mpv)
      assert Playback.resume_supported?()

      Application.put_env(:playmark, :player, :vlc)
      assert Playback.resume_supported?()

      Application.put_env(:playmark, :player, :ffplay)
      refute Playback.resume_supported?()
    end
  end

  describe "format/0" do
    test "defaults to a 1080p cap when :max_height is unset" do
      original = Application.fetch_env(:playmark, :max_height)
      Application.delete_env(:playmark, :max_height)
      on_exit(fn -> restore_max_height(original) end)

      assert Playback.format() == "bestvideo[height<=1080]+bestaudio/best"
    end

    test "honors a configured :max_height" do
      original = Application.fetch_env(:playmark, :max_height)
      Application.put_env(:playmark, :max_height, 720)
      on_exit(fn -> restore_max_height(original) end)

      assert Playback.format() == "bestvideo[height<=720]+bestaudio/best"
    end
  end

  describe "subtitles?/0, subtitle_default/0 and subtitle_fallback/0" do
    test "default to captions on, English default, no fallback, when unset" do
      original_on = Application.fetch_env(:playmark, :subtitles)
      original_default = Application.fetch_env(:playmark, :subtitle_default)
      original_fallback = Application.fetch_env(:playmark, :subtitle_fallback)
      Application.delete_env(:playmark, :subtitles)
      Application.delete_env(:playmark, :subtitle_default)
      Application.delete_env(:playmark, :subtitle_fallback)

      on_exit(fn ->
        restore(:subtitles, original_on)
        restore(:subtitle_default, original_default)
        restore(:subtitle_fallback, original_fallback)
      end)

      assert Playback.subtitles?() == true
      assert Playback.subtitle_default() == "en"
      assert Playback.subtitle_fallback() == nil
    end

    test "honor configured values" do
      original_on = Application.fetch_env(:playmark, :subtitles)
      original_default = Application.fetch_env(:playmark, :subtitle_default)
      original_fallback = Application.fetch_env(:playmark, :subtitle_fallback)
      Application.put_env(:playmark, :subtitles, false)
      Application.put_env(:playmark, :subtitle_default, "id")
      Application.put_env(:playmark, :subtitle_fallback, "en")

      on_exit(fn ->
        restore(:subtitles, original_on)
        restore(:subtitle_default, original_default)
        restore(:subtitle_fallback, original_fallback)
      end)

      assert Playback.subtitles?() == false
      assert Playback.subtitle_default() == "id"
      assert Playback.subtitle_fallback() == "en"
    end
  end

  describe "play/2 with an unsupported player" do
    test "returns an error tuple" do
      assert {:error, "unsupported player: :foo"} = Playback.play("https://youtu.be/x", :foo)
    end
  end

  describe "play_local/2 with an unsupported player" do
    test "returns an error tuple" do
      assert {:error, "unsupported player: :foo"} = Playback.play_local("/tmp/a.mp4", :foo)
    end
  end

  describe "parse_stream_urls/1" do
    test "extracts the URL, skipping yt-dlp warning lines" do
      output = """
      WARNING: Your yt-dlp version is older than 90 days!
               It is strongly recommended to always use the latest version.
      https://rr2---sn-cp1oxu.googlevideo.com/videoplayback?expire=123
      """

      assert Playback.parse_stream_urls(output) ==
               ["https://rr2---sn-cp1oxu.googlevideo.com/videoplayback?expire=123"]
    end

    test "keeps both URLs, video first, for a split rendition" do
      output = "https://video.example/stream\nhttps://audio.example/stream\n"

      assert Playback.parse_stream_urls(output) ==
               ["https://video.example/stream", "https://audio.example/stream"]
    end

    test "trims surrounding whitespace" do
      assert Playback.parse_stream_urls("  https://example.com/s  \n") ==
               ["https://example.com/s"]
    end

    test "returns an empty list when there is no URL" do
      assert Playback.parse_stream_urls("WARNING: nothing here\n") == []
      assert Playback.parse_stream_urls("") == []
    end
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:playmark, key, value)
  defp restore(key, :error), do: Application.delete_env(:playmark, key)

  defp restore_env({:ok, value}), do: Application.put_env(:playmark, :player, value)
  defp restore_env(:error), do: Application.delete_env(:playmark, :player)

  defp restore_max_height({:ok, value}), do: Application.put_env(:playmark, :max_height, value)
  defp restore_max_height(:error), do: Application.delete_env(:playmark, :max_height)
end
