defmodule Playmark.ExploreTest do
  use ExUnit.Case, async: true

  alias Playmark.Explore

  @sep "\x1F"

  describe "build_args/1" do
    test "builds a bounded flat-playlist request for YouTube's recommended feed" do
      assert Explore.build_args(20) == [
               "--socket-timeout",
               "30",
               "--playlist-end",
               "20",
               "--flat-playlist",
               "--print",
               "%(extractor_key)s#{@sep}%(id)s#{@sep}%(title)s#{@sep}%(live_status)s#{@sep}%(duration)s#{@sep}%(view_count)s#{@sep}%(url)s",
               "https://www.youtube.com"
             ]
    end
  end

  describe "parse_videos/1" do
    test "keeps playable videos and Shorts with their emitted URLs, parsing metadata" do
      output =
        Enum.join(
          [
            line(
              "Youtube",
              "abcdefghijk",
              "Regular",
              "not_live",
              "563",
              "4000000",
              "https://www.youtube.com/watch?v=abcdefghijk"
            ),
            line(
              "Youtube",
              "123456789_-",
              "Short",
              "is_live",
              "NA",
              "NA",
              "https://www.youtube.com/shorts/123456789_-"
            )
          ],
          "\n"
        )

      assert Explore.parse_videos(output) == [
               %{
                 id: "abcdefghijk",
                 title: "Regular",
                 url: "https://www.youtube.com/watch?v=abcdefghijk",
                 live: :none,
                 duration: 563,
                 views: 4_000_000
               },
               %{
                 id: "123456789_-",
                 title: "Short",
                 url: "https://www.youtube.com/shorts/123456789_-",
                 live: :live,
                 duration: nil,
                 views: nil
               }
             ]
    end

    test "drops playlists, channels, malformed rows, and fabricated video URLs" do
      output =
        Enum.join(
          [
            "WARNING: update yt-dlp",
            line(
              "YoutubeTab",
              "PL123",
              "Playlist",
              "NA",
              "NA",
              "NA",
              "https://www.youtube.com/playlist?list=PL123"
            ),
            line(
              "YoutubeTab",
              "UC123",
              "Channel",
              "NA",
              "NA",
              "NA",
              "https://www.youtube.com/channel/UC123"
            ),
            line("Youtube", "NA", "Missing ID", "NA", "NA", "NA", "NA"),
            line(
              "Youtube",
              "abcdefghijk",
              "",
              "NA",
              "NA",
              "NA",
              "https://www.youtube.com/watch?v=abcdefghijk"
            ),
            line(
              "Youtube",
              "abcdefghijk",
              "Wrong URL",
              "NA",
              "NA",
              "NA",
              "https://www.youtube.com/watch?v=xxxxxxxxxxx"
            ),
            "not a structured row"
          ],
          "\n"
        )

      assert Explore.parse_videos(output) == []
    end

    test "normalizes past and upcoming live statuses" do
      output =
        Enum.join(
          [
            line(
              "Youtube",
              "abcdefghijk",
              "Past",
              "was_live",
              "NA",
              "NA",
              "https://youtu.be/abcdefghijk"
            ),
            line(
              "Youtube",
              "123456789_-",
              "Soon",
              "is_upcoming",
              "NA",
              "NA",
              "https://www.youtube.com/watch?v=123456789_-"
            )
          ],
          "\n"
        )

      assert [%{live: :ended}, %{live: :upcoming}] = Explore.parse_videos(output)
    end
  end

  defp line(extractor, id, title, status, duration, views, url) do
    Enum.join([extractor, id, title, status, duration, views, url], @sep)
  end
end
