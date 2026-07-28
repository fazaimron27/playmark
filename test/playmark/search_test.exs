defmodule Playmark.SearchTest do
  use ExUnit.Case, async: true

  alias Playmark.Search

  describe "build_args/2" do
    test "builds a ytsearchN: pseudo-URL with the flat-playlist print format" do
      args = Search.build_args("today's news", 20)

      assert args == [
               "--socket-timeout",
               "30",
               "--flat-playlist",
               "--print",
               "%(id)s\x1F%(title)s\x1F%(live_status)s\x1F%(duration)s\x1F%(view_count)s",
               "ytsearch20:today's news"
             ]

      # The id/title separator must be the same ASCII Unit Separator (0x1F)
      # Playmark.Channel.parse_videos/1 splits on, or search output won't parse.
      assert Enum.any?(args, &String.contains?(&1, "\x1F"))
    end

    test "encodes the limit into the search count" do
      assert ["--socket-timeout", "30", "--flat-playlist", "--print", _, "ytsearch5:cats"] =
               Search.build_args("cats", 5)
    end

    test "passes the query verbatim as a single arg (no shell, no injection)" do
      # Shell metacharacters stay literal: the query is one element of the arg
      # list handed straight to yt-dlp, never interpolated into a shell string.
      injection = "news; rm -rf / #"
      args = Search.build_args(injection, 20)

      assert List.last(args) == "ytsearch20:#{injection}"
    end
  end

  describe "search/2" do
    test "returns an error for an empty (or whitespace-only) query without shelling out" do
      assert {:error, _} = Search.search("")
      assert {:error, _} = Search.search("   ")
    end
  end
end
