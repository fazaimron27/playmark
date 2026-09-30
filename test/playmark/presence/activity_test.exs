defmodule Playmark.Presence.ActivityTest do
  use ExUnit.Case, async: true

  alias Playmark.Presence.Activity

  @url "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

  defp card(overrides \\ %{}) do
    Map.merge(
      %{
        title: "Segments, 403s, and the avformat demuxer",
        author: "Some Channel",
        url: @url,
        video_id: "dQw4w9WgXcQ",
        start_ms: 1_790_778_375_000,
        duration_ms: nil
      },
      overrides
    )
  end

  test "builds a Watching card" do
    activity = Activity.build(card())

    assert activity["type"] == 3
    assert activity["status_display_type"] == 1
    assert activity["instance"] == false
    assert activity["details"] == "Segments, 403s, and the avformat demuxer"
    assert activity["state"] == "Some Channel"
  end

  test "links the card and its image to the video, and adds a Watch button" do
    activity = Activity.build(card())

    assert activity["details_url"] == @url
    assert activity["assets"]["large_image"] == "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg"
    assert activity["assets"]["large_url"] == @url
    assert activity["assets"]["large_text"] == "Segments, 403s, and the avformat demuxer"
    assert activity["buttons"] == [%{"label" => "Watch on YouTube", "url" => @url}]
  end

  test "omits assets entirely when there is no video id" do
    activity = Activity.build(card(%{video_id: nil}))

    refute Map.has_key?(activity, "assets")
    assert activity["details_url"] == @url
  end

  test "omits the channel when it is unknown, rather than sending it blank" do
    assert Activity.build(card(%{author: nil}))["state"] == nil
    refute Map.has_key?(Activity.build(card(%{author: nil})), "state")
    refute Map.has_key?(Activity.build(card(%{author: ""})), "state")
  end

  test "drops every URL when the video URL is malformed" do
    activity = Activity.build(card(%{url: "not a url"}))

    refute Map.has_key?(activity, "details_url")
    refute Map.has_key?(activity, "buttons")

    # The thumbnail survives: it is built from the video id with no request, so a
    # URL that failed validation costs the *link*, not the image. It is the
    # clickable `large_url` that goes, per the spec's "omitted when there is no id"
    # being the only condition on the image itself.
    assert activity["assets"]["large_image"] == "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg"
    refute Map.has_key?(activity["assets"], "large_url")
  end

  test "omits the URLs for a non-YouTube URL" do
    activity = Activity.build(card(%{url: "/home/user/video.mkv"}))

    refute Map.has_key?(activity, "details_url")
    refute Map.has_key?(activity, "buttons")
  end

  test "truncates the title to 48 runes and the channel to 40" do
    title = String.duplicate("a", 60)
    author = String.duplicate("b", 60)

    activity = Activity.build(card(%{title: title, author: author}))

    assert String.length(activity["details"]) == 48
    assert String.length(activity["state"]) == 40
  end

  test "keeps a multi-byte title valid across the rune boundary" do
    title = String.duplicate("動", 60)
    activity = Activity.build(card(%{title: title}))

    assert String.length(activity["details"]) == 48
    assert String.valid?(activity["details"])
  end

  test "caps the hover text at 128 bytes without cutting a codepoint" do
    title = String.duplicate("動", 100)
    activity = Activity.build(card(%{title: title}))

    text = activity["assets"]["large_text"]

    assert byte_size(text) <= 128
    assert String.valid?(text)
  end

  test "sends only a start timestamp before the card is anchored" do
    assert Activity.build(card())["timestamps"] == %{"start" => 1_790_778_375_000}
  end

  test "adds an end timestamp once anchored" do
    activity = Activity.build(card(%{duration_ms: 300_000}))

    assert activity["timestamps"] == %{
             "start" => 1_790_778_375_000,
             "end" => 1_790_778_675_000
           }
  end

  test "omits the end timestamp for a zero or live duration" do
    refute Map.has_key?(Activity.build(card(%{duration_ms: 0}))["timestamps"], "end")
    refute Map.has_key?(Activity.build(card(%{duration_ms: nil}))["timestamps"], "end")
  end

  test "omits timestamps entirely when there is no start" do
    refute Map.has_key?(Activity.build(card(%{start_ms: nil})), "timestamps")
  end
end
