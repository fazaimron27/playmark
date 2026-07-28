defmodule Playmark.Player.CaptionsTest do
  use ExUnit.Case, async: true

  alias Playmark.Player.Captions

  describe "select/2" do
    # A probe map as yt-dlp -J produces it: manual tracks under "subtitles",
    # auto-generated under "automatic_captions", and the spoken "language".
    defp probe(manual, auto, language) do
      %{
        "subtitles" => Map.new(manual, &{&1, []}),
        "automatic_captions" => Map.new(auto, &{&1, []}),
        "language" => language
      }
    end

    defp opts(default, fallback) do
      %{subtitle_default: default, subtitle_fallback: fallback}
    end

    test "prefers a manual track in the default language" do
      p = probe(["en", "fr"], ["id"], "id")
      assert Captions.select(p, opts("en", "fr")) == {:manual, "en"}
    end

    test "falls back to a manual track in the fallback language" do
      p = probe(["fr", "de"], ["id"], "id")
      assert Captions.select(p, opts("en", "fr")) == {:manual, "fr"}
    end

    test "falls back to the auto track in the spoken language when no manual matches" do
      p = probe([], ["id", "en"], "id")
      assert Captions.select(p, opts("en", "de")) == {:auto, "id"}
    end

    test "matches a language by prefix (en accepts en-US)" do
      p = probe(["en-US"], [], "en")
      assert Captions.select(p, opts("en", nil)) == {:manual, "en-US"}
    end

    test "matches an -orig auto track for the spoken language" do
      p = probe([], ["id-orig"], "id")
      assert Captions.select(p, opts("en", nil)) == {:auto, "id-orig"}
    end

    test "a nil fallback is skipped" do
      p = probe(["fr"], ["id"], "id")
      # default en misses, fallback nil is skipped, auto in spoken (id) wins.
      assert Captions.select(p, opts("en", nil)) == {:auto, "id"}
    end

    test "returns :none when nothing matches and the spoken language has no auto track" do
      p = probe(["fr"], ["fr"], "de")
      assert Captions.select(p, opts("en", "es")) == :none
    end

    test "returns :none when the spoken language is unknown and no manual matches" do
      p = probe([], ["id"], nil)
      assert Captions.select(p, opts("en", nil)) == :none
    end
  end

  describe "chapters/1" do
    test "returns the chapter count when the array is present" do
      probe = %{"chapters" => [%{"title" => "Intro"}, %{"title" => "Part 1"}]}
      assert Captions.chapters(probe) == 2
    end

    test "returns 0 for an empty chapters array" do
      assert Captions.chapters(%{"chapters" => []}) == 0
    end

    test "returns 0 when the key is absent" do
      assert Captions.chapters(%{"subtitles" => %{}}) == 0
    end

    test "returns 0 when chapters is not a list" do
      assert Captions.chapters(%{"chapters" => nil}) == 0
    end
  end

  describe "cleanup/1" do
    test "removes a downloaded caption file" do
      path =
        Path.join(
          System.tmp_dir!(),
          "playmark-captions-test-#{System.unique_integer([:positive])}.vtt"
        )

      File.write!(path, "WEBVTT\n")
      assert File.exists?(path)

      assert Captions.cleanup(path) == :ok
      refute File.exists?(path)
    end

    test "is a no-op for nil (no track was downloaded)" do
      assert Captions.cleanup(nil) == :ok
    end

    test "does not raise when the file is already gone" do
      path =
        Path.join(
          System.tmp_dir!(),
          "playmark-captions-missing-#{System.unique_integer([:positive])}.vtt"
        )

      refute File.exists?(path)

      # A best-effort cleanup on a vanished temp file must not crash playback teardown.
      assert Captions.cleanup(path) == {:error, :enoent}
    end
  end
end
