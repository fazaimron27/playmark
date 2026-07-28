defmodule Playmark.ChannelTest do
  # async: false — the enrich_titles/1 tests set a stubbed metadata impl and a
  # url->result mapping in global application env, which parallel modules must
  # not observe.
  use ExUnit.Case, async: false

  alias Playmark.Channel

  describe "parse_videos/1" do
    test "parses id/title lines into video maps with a watch URL" do
      output =
        "9LeEEBzjltY\x1FThe Mystery of Ancient Religions\nU8dc4e6uhq8\x1FIs Netanyahu the Last Leader?\n"

      assert [
               %{
                 id: "9LeEEBzjltY",
                 title: "The Mystery of Ancient Religions",
                 url: "https://www.youtube.com/watch?v=9LeEEBzjltY"
               },
               %{
                 id: "U8dc4e6uhq8",
                 title: "Is Netanyahu the Last Leader?",
                 url: "https://www.youtube.com/watch?v=U8dc4e6uhq8"
               }
             ] = Channel.parse_videos(output)
    end

    test "parses the live_status field into a :live tag" do
      output =
        "a\x1FLive now\x1Fis_live\n" <>
          "b\x1FPast stream\x1Fwas_live\n" <>
          "c\x1FPost-live processing\x1Fpost_live\n" <>
          "d\x1FScheduled\x1Fis_upcoming\n" <>
          "e\x1FRegular upload\x1Fnot_live\n"

      assert [
               %{id: "a", live: :live},
               %{id: "b", live: :ended},
               %{id: "c", live: :ended},
               %{id: "d", live: :upcoming},
               %{id: "e", live: :none}
             ] = Channel.parse_videos(output)
    end

    test "treats an unknown or NA status as :none" do
      output = "a\x1FTitle\x1FNA\nb\x1FTitle\x1Fsomething_new\n"
      assert [%{live: :none}, %{live: :none}] = Channel.parse_videos(output)
    end

    test "falls back to :none for a legacy 2-field line (no status column)" do
      output = "abc123\x1FReal Title\n"
      assert [%{id: "abc123", title: "Real Title", live: :none}] = Channel.parse_videos(output)
    end

    test "drops lines without the separator (e.g. yt-dlp warnings)" do
      output = "WARNING: yt-dlp is out of date\nabc123\x1FReal Title\x1Fnot_live\n"

      assert [%{id: "abc123", title: "Real Title"}] = Channel.parse_videos(output)
    end

    test "keeps titles that themselves contain separators or punctuation" do
      output = "id1\x1FA title | with: punctuation & symbols\x1Fnot_live\n"

      assert [%{id: "id1", title: "A title | with: punctuation & symbols"}] =
               Channel.parse_videos(output)
    end

    test "parses duration (seconds) and view_count into integers" do
      output = "abc123\x1FReal Title\x1Fnot_live\x1F563\x1F4000000\n"

      assert [%{id: "abc123", duration: 563, views: 4_000_000}] = Channel.parse_videos(output)
    end

    test "leaves duration/views nil for NA, blank, or a shorter line" do
      output =
        "a\x1FNA fields\x1Fnot_live\x1FNA\x1FNA\n" <>
          "b\x1FBlank fields\x1Fnot_live\x1F\x1F\n" <>
          "c\x1FStatus only\x1Fnot_live\n" <>
          "d\x1FLegacy two-field\n"

      assert [
               %{id: "a", duration: nil, views: nil},
               %{id: "b", duration: nil, views: nil},
               %{id: "c", duration: nil, views: nil},
               %{id: "d", duration: nil, views: nil}
             ] = Channel.parse_videos(output)
    end

    test "returns an empty list when there are no video lines" do
      assert Channel.parse_videos("WARNING: nothing\n") == []
      assert Channel.parse_videos("") == []
    end
  end

  describe "channel playlists" do
    test "builds a bounded flat-playlist request for the canonical Playlists tab" do
      args = Channel.playlist_args("https://www.youtube.com/@channel/videos", 25)

      assert args == [
               "--socket-timeout",
               "30",
               "--playlist-end",
               "25",
               "--flat-playlist",
               "--print",
               "%(extractor_key)s\x1F%(id)s\x1F%(title)s\x1F%(url)s",
               "https://www.youtube.com/@channel/playlists"
             ]
    end

    test "drops channel share query parameters before appending the tab" do
      args = Channel.playlist_args("https://www.youtube.com/@channel/videos?si=shared", 10)
      assert List.last(args) == "https://www.youtube.com/@channel/playlists"
    end

    test "parses playlist containers, canonicalizes URLs, and preserves order" do
      output =
        "YoutubeTab\x1FPL_one\x1FFirst Playlist\x1Fhttps://www.youtube.com/playlist?list=PL_one&si=x\n" <>
          "YoutubeTab\x1FPL_two\x1FSecond Playlist\x1Fhttps://www.youtube.com/watch?v=abc&list=PL_two\n"

      assert Channel.parse_playlists(output) == [
               %{
                 id: "PL_one",
                 title: "First Playlist",
                 url: "https://www.youtube.com/playlist?list=PL_one"
               },
               %{
                 id: "PL_two",
                 title: "Second Playlist",
                 url: "https://www.youtube.com/playlist?list=PL_two"
               }
             ]
    end

    test "drops warnings, non-playlist rows, invalid URLs, and unavailable titles" do
      output =
        "WARNING: stale yt-dlp\n" <>
          "Youtube\x1Fabcdefghijk\x1FVideo\x1Fhttps://www.youtube.com/watch?v=abcdefghijk\n" <>
          "YoutubeTab\x1FPL_bad\x1FNA\x1Fhttps://www.youtube.com/playlist?list=PL_bad\n" <>
          "YoutubeTab\x1FPL_bad\x1FBad URL\x1Fhttps://example.com/playlist?list=PL_bad\n"

      assert Channel.parse_playlists(output) == []
    end
  end

  describe "enrich_titles/1" do
    setup do
      Application.put_env(:playmark, :metadata_impl, StubMetadata)
      # enrich_titles/1 memoizes titles in Playmark.Cache by id. These tests reuse
      # ids ("a", "b", "1".."5") with different expected titles, so clear the
      # cache between them or an earlier title would leak into a later run.
      Playmark.Cache.clear()

      on_exit(fn ->
        Application.delete_env(:playmark, :metadata_impl)
        Application.delete_env(:playmark, :stub_metadata)
      end)
    end

    test "replaces flat titles with oEmbed (original-language) titles and sets author" do
      videos = [
        %{id: "a", title: "The Mystery of Ancient Religions", url: "https://youtu.be/a"},
        %{id: "b", title: "Is Netanyahu the Last Leader?", url: "https://youtu.be/b"}
      ]

      StubMetadata.set(%{
        "https://youtu.be/a" =>
          {:ok, %{title: "Misteri Agama Kuno di Al-Qur'an", channel: "Chan A"}},
        "https://youtu.be/b" =>
          {:ok, %{title: "Benarkah Netanyahu Pemimpin Terakhir Israel?", channel: "Chan B"}}
      })

      assert [
               %{id: "a", title: "Misteri Agama Kuno di Al-Qur'an", author: "Chan A"},
               %{id: "b", title: "Benarkah Netanyahu Pemimpin Terakhir Israel?", author: "Chan B"}
             ] = Channel.enrich_titles(videos)
    end

    test "keeps the flat title and sets a nil author when oEmbed fails (no drops)" do
      videos = [
        %{id: "a", title: "Flat A", url: "https://youtu.be/a"},
        %{id: "b", title: "Flat B", url: "https://youtu.be/b"}
      ]

      StubMetadata.set(%{
        "https://youtu.be/a" => {:ok, %{title: "Original A", channel: "Chan A"}},
        "https://youtu.be/b" => {:error, "boom"}
      })

      assert [
               %{id: "a", title: "Original A", author: "Chan A"},
               %{id: "b", title: "Flat B", author: nil}
             ] = Channel.enrich_titles(videos)
    end

    test "preserves order" do
      videos = for i <- 1..5, do: %{id: "#{i}", title: "flat#{i}", url: "https://youtu.be/#{i}"}

      StubMetadata.set(
        Map.new(videos, fn v -> {v.url, {:ok, %{title: "orig#{v.id}", channel: "C"}}} end)
      )

      assert Channel.enrich_titles(videos) |> Enum.map(& &1.id) == ["1", "2", "3", "4", "5"]
    end

    test "preserves the :duration and :views fields while replacing the title" do
      videos = [
        %{id: "a", title: "Flat A", url: "https://youtu.be/a", duration: 563, views: 4_000_000},
        %{id: "b", title: "Flat B", url: "https://youtu.be/b", duration: nil, views: nil}
      ]

      StubMetadata.set(%{
        "https://youtu.be/a" => {:ok, %{title: "Original A", channel: "C"}},
        "https://youtu.be/b" => {:ok, %{title: "Original B", channel: "C"}}
      })

      assert [
               %{id: "a", title: "Original A", duration: 563, views: 4_000_000},
               %{id: "b", title: "Original B", duration: nil, views: nil}
             ] = Channel.enrich_titles(videos)
    end

    test "returns [] for an empty list without calling oEmbed" do
      assert Channel.enrich_titles([]) == []
    end

    test "preserves the :live tag while replacing the title" do
      videos = [
        %{id: "a", title: "Flat A", url: "https://youtu.be/a", live: :live},
        %{id: "b", title: "Flat B", url: "https://youtu.be/b", live: :none}
      ]

      StubMetadata.set(%{
        "https://youtu.be/a" => {:ok, %{title: "Original A", channel: "C"}},
        "https://youtu.be/b" => {:ok, %{title: "Original B", channel: "C"}}
      })

      assert [
               %{id: "a", title: "Original A", live: :live},
               %{id: "b", title: "Original B", live: :none}
             ] = Channel.enrich_titles(videos)
    end

    test "serves repeat lookups from the cache without re-fetching" do
      videos = [
        %{id: "a", title: "Flat A", url: "https://youtu.be/a"},
        %{id: "b", title: "Flat B", url: "https://youtu.be/b"}
      ]

      StubMetadata.set(%{
        "https://youtu.be/a" => {:ok, %{title: "Original A", channel: "C"}},
        "https://youtu.be/b" => {:ok, %{title: "Original B", channel: "C"}}
      })

      # First pass populates the cache from oEmbed.
      assert [%{title: "Original A"}, %{title: "Original B"}] = Channel.enrich_titles(videos)
      # Caching is a cast; flush it before relying on a hit below.
      Playmark.Cache.sync()

      # Now make every oEmbed lookup fail. If the second pass still yields the
      # original titles and authors, they came from the cache rather than the
      # network — a cache miss here would fall back to the flat titles / nil author.
      StubMetadata.set(%{})

      assert [
               %{title: "Original A", author: "C"},
               %{title: "Original B", author: "C"}
             ] = Channel.enrich_titles(videos)
    end
  end
end

defmodule StubMetadata do
  @moduledoc false
  # enrich_titles/1 fans out over Task.async_stream, so fetch/1 runs in child
  # processes that don't share the test's process dictionary. Keep the url ->
  # result mapping in application env, which every process can read. Only
  # ChannelTest sets this, and its tests run sequentially, so there's no clash.
  def set(mapping), do: Application.put_env(:playmark, :stub_metadata, mapping)

  def fetch(url) do
    case Application.get_env(:playmark, :stub_metadata) do
      nil -> {:error, "no stub configured"}
      mapping -> Map.get(mapping, url, {:error, "not stubbed: #{url}"})
    end
  end
end
