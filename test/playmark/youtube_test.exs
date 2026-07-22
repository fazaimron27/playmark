defmodule Playmark.YouTubeTest do
  use ExUnit.Case, async: true

  alias Playmark.YouTube

  describe "validate/1" do
    test "accepts watch, short-link, and channel URLs on YouTube hosts" do
      urls = [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com/watch?v=dQw4w9WgXcQ",
        "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ",
        "https://www.youtube.com/@handle/videos",
        "https://www.youtube.com/channel/UCabc123"
      ]

      for url <- urls do
        assert {:ok, ^url} = YouTube.validate(url)
      end
    end

    test "accepts http as well as https" do
      assert {:ok, _} = YouTube.validate("http://youtube.com/watch?v=x")
    end

    test "matches the host case-insensitively" do
      assert {:ok, _} = YouTube.validate("https://WWW.YouTube.com/watch?v=x")
    end

    test "rejects a non-YouTube host" do
      assert {:error, _} = YouTube.validate("https://vimeo.com/12345")
      assert {:error, _} = YouTube.validate("https://youtube.evil.com/watch?v=x")
    end

    test "rejects a bare word or a non-URL string" do
      assert {:error, _} = YouTube.validate("cats")
      assert {:error, _} = YouTube.validate("not a url at all")
      assert {:error, _} = YouTube.validate("")
    end

    test "rejects a URL with no scheme" do
      assert {:error, _} = YouTube.validate("youtube.com/watch?v=x")
    end
  end

  describe "canonical_channel_url/1" do
    test "strips a trailing channel-tab segment" do
      assert YouTube.canonical_channel_url("https://www.youtube.com/@AmmarTV/videos") ==
               "https://www.youtube.com/@AmmarTV"

      assert YouTube.canonical_channel_url("https://www.youtube.com/@AmmarTV/streams") ==
               "https://www.youtube.com/@AmmarTV"

      assert YouTube.canonical_channel_url("https://www.youtube.com/@AmmarTV/shorts") ==
               "https://www.youtube.com/@AmmarTV"
    end

    test "strips a trailing tab from a /channel/UC… URL too" do
      assert YouTube.canonical_channel_url("https://www.youtube.com/channel/UCabc/streams") ==
               "https://www.youtube.com/channel/UCabc"
    end

    test "leaves an already-bare channel URL unchanged" do
      url = "https://www.youtube.com/@AmmarTV"
      assert YouTube.canonical_channel_url(url) == url
    end

    test "does not strip a non-tab final segment" do
      url = "https://www.youtube.com/@AmmarTV/somethingelse"
      assert YouTube.canonical_channel_url(url) == url
    end

    test "leaves watch and short links unchanged (v/live are not stripped mid-URL)" do
      watch = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
      short = "https://youtu.be/dQw4w9WgXcQ"
      assert YouTube.canonical_channel_url(watch) == watch
      assert YouTube.canonical_channel_url(short) == short
    end

    test "is idempotent — canonicalizing a canonical URL is a no-op" do
      once = YouTube.canonical_channel_url("https://www.youtube.com/@AmmarTV/videos")
      assert YouTube.canonical_channel_url(once) == once
    end

    test "returns non-string input as-is" do
      assert YouTube.canonical_channel_url(nil) == nil
      assert YouTube.canonical_channel_url(123) == 123
    end
  end
end
