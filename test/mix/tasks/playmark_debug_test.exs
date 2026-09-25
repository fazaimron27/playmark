defmodule Mix.Tasks.Playmark.DebugTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Playmark.Debug

  # A trimmed-down shape of what YouTube's HLS playlists actually look like:
  # absolute segment URLs, one per #EXTINF, with directives interleaved.
  @manifest """
  #EXTM3U
  #EXT-X-VERSION:3
  #EXT-X-PLAYLIST-TYPE:VOD
  #EXT-X-TARGETDURATION:6
  #EXTINF:5.12,
  https://rr6.googlevideo.com/videoplayback/gosq/0/file/seg.ts
  #EXTINF:5.12,
  https://rr6.googlevideo.com/videoplayback/gosq/1/file/seg.ts
  #EXTINF:4.64,
  https://rr6.googlevideo.com/videoplayback/gosq/2/file/seg.ts
  #EXT-X-ENDLIST
  """

  describe "hls_manifest?/1" do
    test "recognises a playlist by its required first directive" do
      assert Debug.hls_manifest?(@manifest)
      assert Debug.hls_manifest?("#EXTM3U\n#EXTINF:1,\nhttps://x/seg.ts\n")
    end

    test "rejects anything that is not a playlist" do
      refute Debug.hls_manifest?("")
      refute Debug.hls_manifest?(<<0, 1, 2, 3>>)
      refute Debug.hls_manifest?("<html><body>nope</body></html>")
    end
  end

  describe "parse_hls_segments/1" do
    test "returns the segment URLs in playlist order" do
      assert Debug.parse_hls_segments(@manifest) == [
               "https://rr6.googlevideo.com/videoplayback/gosq/0/file/seg.ts",
               "https://rr6.googlevideo.com/videoplayback/gosq/1/file/seg.ts",
               "https://rr6.googlevideo.com/videoplayback/gosq/2/file/seg.ts"
             ]
    end

    test "ignores directives, comments, and blank lines" do
      body = """
      #EXTM3U

      # a plain comment
      #EXT-X-TARGETDURATION:6
      #EXTINF:5.0,
      https://host/a.ts

      #EXTINF:5.0,
      https://host/b.ts
      """

      assert Debug.parse_hls_segments(body) == ["https://host/a.ts", "https://host/b.ts"]
    end

    test "trims surrounding whitespace from segment lines" do
      body = "#EXTM3U\n#EXTINF:1,\n  https://host/a.ts  \n"

      assert Debug.parse_hls_segments(body) == ["https://host/a.ts"]
    end

    test "returns nothing for a body that is not a playlist" do
      assert Debug.parse_hls_segments("not a manifest") == []
      assert Debug.parse_hls_segments("") == []
    end

    # YouTube's playlists always carry absolute segment URLs, so resolving
    # relative URIs against a base is deliberately not implemented. A playlist
    # that used them reports zero segments, which the task surfaces as a count
    # rather than silently passing.
    test "skips relative segment URIs rather than guessing a base URL" do
      body = "#EXTM3U\n#EXTINF:1,\nseg-0.ts\n#EXTINF:1,\nhttps://host/seg-1.ts\n"

      assert Debug.parse_hls_segments(body) == ["https://host/seg-1.ts"]
    end
  end

  # A probe result is %{status: integer | :error, segments: nil | [integer | :error]},
  # where `segments` is nil for a URL that was not an HLS playlist.
  describe "verdict/1" do
    test "a reachable non-HLS URL passes" do
      assert Debug.verdict([%{status: 206, segments: nil}]) == "OK (206)"
    end

    test "a split rendition reports both URLs" do
      probes = [%{status: 206, segments: nil}, %{status: 206, segments: nil}]

      assert Debug.verdict(probes) == "OK (206,206)"
    end

    test "an unreachable URL fails regardless of segments" do
      assert Debug.verdict([%{status: 403, segments: nil}]) == "FAIL (403)"
      assert Debug.verdict([%{status: :error, segments: nil}]) == "FAIL (ERR)"
    end

    test "a manifest whose sampled segments all fetch passes" do
      assert Debug.verdict([%{status: 200, segments: [200, 200, 200]}]) ==
               "OK (200, 3/3 segments)"
    end

    # The distinction this whole check exists for: a manifest that serves fine
    # while some of its segments do not. ffmpeg tolerates this and plays; VLC's
    # adaptive demuxer can die on it. Neither OK nor FAIL describes that.
    test "a manifest with some failing segments is neither pass nor fail" do
      assert Debug.verdict([%{status: 200, segments: [403, 200, 200]}]) ==
               "PARTIAL (1/3 segments failed)"

      assert Debug.verdict([%{status: 200, segments: [403, :error, 200]}]) ==
               "PARTIAL (2/3 segments failed)"
    end

    test "a manifest with no fetchable segments fails" do
      assert Debug.verdict([%{status: 200, segments: [403, 403, 403]}]) ==
               "FAIL (3/3 segments failed)"
    end

    test "a manifest with no parseable segments reports that, not a pass" do
      assert Debug.verdict([%{status: 200, segments: []}]) == "FAIL (no segments parsed)"
    end
  end
end
