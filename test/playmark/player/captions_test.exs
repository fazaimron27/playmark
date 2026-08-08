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

    # `translate?` defaults to the shipped default (machine translation accepted).
    defp opts(default, fallback, translate? \\ true) do
      %{
        subtitle_default: default,
        subtitle_fallback: fallback,
        subtitle_translate: translate?
      }
    end

    test "prefers a manual track in the default language" do
      p = probe(["en", "fr"], ["id"], "id")
      assert Captions.select(p, opts("en", "fr")) == {:manual, "en"}
    end

    test "a translation into the default language beats a manual track in the fallback" do
      # Language first, quality second: listing two languages ranks them, so the
      # first-choice language wins even when only a machine translation serves it.
      p = probe(["fr"], ["en"], "fr")
      assert Captions.select(p, opts("en", "fr")) == {:translated, "en"}
    end

    test "falls back to a manual track in the fallback language" do
      p = probe(["fr", "de"], [], "id")
      assert Captions.select(p, opts("en", "fr")) == {:manual, "fr"}
    end

    test "prefers a translated auto track in the default language over the spoken one" do
      # YouTube lists the spoken transcript machine-translated into ~150
      # languages, so the requested "en" is available on an Indonesian video.
      p = probe([], ["id", "en"], "id")
      assert Captions.select(p, opts("en", "de")) == {:translated, "en"}
    end

    test "falls back to a translated auto track in the fallback language" do
      p = probe([], ["id", "de"], "id")
      assert Captions.select(p, opts("en", "de")) == {:translated, "de"}
    end

    test "an uploader track beats a translation into the same language" do
      # Quality second: within one language, human-made wins.
      p = probe(["en"], ["en"], "id")
      assert Captions.select(p, opts("en", "de")) == {:manual, "en"}
    end

    test "reaches a translation of an uploader track keyed {target}-{source}" do
      # A Korean podcast with uploader en/ko subs and no ASR track: the only route
      # to Indonesian is translating a manual track. YouTube keys those
      # `{target}-{source}`, and reports no spoken language for such a video.
      p = probe(["en", "ko"], ["id-en", "id-ko", "en", "ko"], nil)
      assert Captions.select(p, opts("id", "en")) == {:translated, "id-en"}
    end

    test "prefers translating the uploader track in a language the user reads" do
      # id-en and id-ko both yield Indonesian; en is the user's fallback, so its
      # human-made text is the better source and they can spot-check a bad line.
      p = probe(["en", "ko"], ["id-ko", "id-en"], "ko")
      assert Captions.select(p, opts("id", "en")) == {:translated, "id-en"}
    end

    test "prefers any uploader source over an ASR-derived translation" do
      # Plain `id` is a translation of the ASR transcript (two lossy passes);
      # id-ko translates the uploader's own Korean text (one).
      p = probe(["ko"], ["id", "id-ko"], "ko")
      assert Captions.select(p, opts("id", nil)) == {:translated, "id-ko"}
    end

    test "translation off ignores {target}-{source} tracks too" do
      p = probe(["en", "ko"], ["id-en", "ko"], "ko")
      assert Captions.select(p, opts("id", "en", false)) == {:manual, "en"}
    end

    test "tags a {target}-{source} track as translated even when it matches the spoken language" do
      # `en-ko` is "English from Korean". Its `en-` prefix matches a spoken `en`,
      # but a translation of the uploader's Korean track is not native ASR.
      p = probe(["ko"], ["en-ko"], "en")
      assert Captions.select(p, opts("en", nil)) == {:translated, "en-ko"}
    end

    test "a regional variant is still native when its suffix names no source track" do
      # `en-US` looks like {target}-{source} but `US` is no track, so the
      # translation rule must not fire and mislabel a plain regional variant.
      p = probe([], ["en-US"], "en")
      assert Captions.select(p, opts("en", nil)) == {:auto, "en-US"}
    end

    test "tags a requested track as :auto when it is the spoken language" do
      # Not a translation: the request and the audio agree, so this is the
      # video's own ASR transcript and must not be labelled auto-translated.
      p = probe([], ["en"], "en")
      assert Captions.select(p, opts("en", nil)) == {:auto, "en"}
    end

    test "tags an -orig variant of the spoken language as :auto, not translated" do
      p = probe([], ["en-orig"], "en")
      assert Captions.select(p, opts("en", nil)) == {:auto, "en-orig"}
    end

    test "tags a match as translated when the spoken language is unknown" do
      # With no spoken language to compare against we can't show the track is
      # native, so it reports as the lower tier rather than overclaiming.
      p = probe([], ["en"], nil)
      assert Captions.select(p, opts("en", nil)) == {:translated, "en"}
    end

    test "falls back to the auto track in the spoken language when translation is off" do
      p = probe([], ["id", "en"], "id")
      assert Captions.select(p, opts("en", "de", false)) == {:auto, "id"}
    end

    test "translation off still prefers an uploader track in the default language" do
      p = probe(["en"], ["id"], "id")
      assert Captions.select(p, opts("en", nil, false)) == {:manual, "en"}
    end

    test "returns :none when translation is off and only unrequested auto tracks exist" do
      p = probe([], ["en"], nil)
      assert Captions.select(p, opts("en", nil, false)) == :none
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
