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
end
