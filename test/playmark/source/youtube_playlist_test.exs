defmodule Playmark.Source.YouTubePlaylistTest do
  use ExUnit.Case, async: true

  alias Playmark.Source.YouTubePlaylist

  describe "command arguments" do
    test "builds a bounded metadata request" do
      assert YouTubePlaylist.metadata_args("https://youtube.com/playlist?list=PL1") == [
               "--socket-timeout",
               "30",
               "--flat-playlist",
               "--playlist-end",
               "1",
               "--no-warnings",
               "--dump-single-json",
               "https://youtube.com/playlist?list=PL1"
             ]
    end

    test "builds a bounded flat entry request" do
      args = YouTubePlaylist.build_args("https://youtube.com/playlist?list=PL1", 100)

      assert [
               "--socket-timeout",
               "30",
               "--playlist-end",
               "100",
               "--flat-playlist",
               "--print",
               template,
               "https://youtube.com/playlist?list=PL1"
             ] = args

      assert template =~ "%(extractor_key)s\x1F%(id)s\x1F%(title)s"
    end
  end

  describe "parse_metadata/1" do
    test "reads title and channel" do
      json = Jason.encode!(%{"title" => "Lessons", "channel" => "Teacher"})
      assert {:ok, %{title: "Lessons", channel: "Teacher"}} = YouTubePlaylist.parse_metadata(json)
    end

    test "allows missing owner and rejects missing title" do
      assert {:ok, %{title: "Lessons", channel: nil}} =
               YouTubePlaylist.parse_metadata(~s({"title":"Lessons"}))

      assert {:error, _} = YouTubePlaylist.parse_metadata(~s({"channel":"Teacher"}))
      assert {:error, _} = YouTubePlaylist.parse_metadata("not json")
    end
  end

  describe "parse_videos/1" do
    test "preserves valid entry order and normalizes metadata" do
      output =
        Enum.join(
          [
            "Youtube\x1Fabcdefghijk\x1FFirst\x1Fnot_live\x1F563\x1F4000000\x1FChannel A",
            "Youtube\x1F123456789_-\x1FSecond\x1Fis_live\x1FNA\x1FNA\x1FNA"
          ],
          "\n"
        )

      assert [first, second] = YouTubePlaylist.parse_videos(output)
      assert first.url == "https://www.youtube.com/watch?v=abcdefghijk"
      assert first.author == "Channel A"
      assert first.live == :none
      assert first.duration == 563
      assert first.views == 4_000_000
      assert second.title == "Second"
      assert second.author == nil
      assert second.live == :live
      assert second.duration == nil
      assert second.views == nil
    end

    test "drops warnings, non-video cards, malformed IDs, and unavailable entries" do
      output =
        Enum.join(
          [
            "WARNING: update yt-dlp",
            "YoutubeTab\x1FPL123\x1FPlaylist\x1FNA\x1FNA\x1FNA\x1FChannel",
            "Youtube\x1Fshort\x1FBad id\x1FNA\x1FNA\x1FNA\x1FChannel",
            "Youtube\x1Fabcdefghijk\x1F[Private video]\x1FNA\x1FNA\x1FNA\x1FNA",
            "Youtube\x1F123456789_-\x1FAvailable\x1Fis_upcoming\x1FNA\x1FNA\x1FChannel"
          ],
          "\n"
        )

      assert [%{title: "Available", live: :upcoming}] = YouTubePlaylist.parse_videos(output)
    end
  end
end
