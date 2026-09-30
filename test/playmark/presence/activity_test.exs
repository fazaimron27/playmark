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

  # Discord counts these fields in UTF-16 code units, not runes and not bytes —
  # measured against a real client: 128 ASCII runes accepted, 129 rejected; 128
  # astral-emoji runes rejected (256 units); 128 CJK runes accepted (384 bytes).
  # A rune cap would therefore let an emoji-heavy title through and have Discord
  # reject the *whole* activity, losing the card entirely rather than shortening
  # a line.
  defp units(text) do
    text
    |> String.to_charlist()
    |> Enum.reduce(0, fn codepoint, acc -> acc + if(codepoint > 0xFFFF, do: 2, else: 1) end)
  end

  test "sends a title that fits Discord's limit whole" do
    # The reported case: a real YouTube title, well inside the limit, was being
    # cut at 48 characters.
    title = "HP yang biasanya juara rekomendasi - Unboxing Redmi Note 17 Pro 5G!"

    activity = Activity.build(card(%{title: title}))

    assert activity["details"] == title
  end

  test "truncates an over-long title and channel, marking the cut" do
    title = String.duplicate("a", 200)
    author = String.duplicate("b", 200)

    activity = Activity.build(card(%{title: title, author: author}))

    # The ellipsis sits *inside* the budget rather than on top of it: a cut that
    # pushed the field back over 128 would be rejected instead of shortened.
    assert activity["details"] == String.duplicate("a", 127) <> "…"
    assert activity["state"] == String.duplicate("b", 127) <> "…"
    assert units(activity["details"]) <= 128
  end

  test "counts an astral character as the two units Discord counts it as" do
    title = String.duplicate("🔥", 100)

    activity = Activity.build(card(%{title: title}))

    # 63 emoji is the most that fits in 127 units; a 64th would overrun.
    assert activity["details"] == String.duplicate("🔥", 63) <> "…"
    assert units(activity["details"]) <= 128
  end

  test "never cuts a codepoint in half" do
    activity = Activity.build(card(%{title: String.duplicate("動", 200)}))

    assert String.valid?(activity["details"])
    assert units(activity["details"]) <= 128
  end

  test "caps the hover text by the same rule as the title" do
    title = String.duplicate("漢", 200)

    activity = Activity.build(card(%{title: title}))

    text = activity["assets"]["large_text"]

    # This title is 600 bytes, which the old byte cap cut to 42 characters —
    # the unit Discord counts was never bytes.
    assert units(text) <= 128
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
