defmodule Playmark.TUI.NavTest do
  use ExUnit.Case, async: true

  alias Playmark.Bookmark
  alias Playmark.TUI.Nav

  describe "jump_index/2" do
    test "an empty list has no index to jump to" do
      assert Nav.jump_index([], :top) == nil
      assert Nav.jump_index([], :bottom) == nil
    end

    test ":top is always the first index" do
      assert Nav.jump_index([:a], :top) == 0
      assert Nav.jump_index([:a, :b, :c], :top) == 0
    end

    test ":bottom is the last index" do
      assert Nav.jump_index([:a], :bottom) == 0
      assert Nav.jump_index([:a, :b, :c], :bottom) == 2
    end
  end

  describe "clamp/3" do
    test "passes through a value already in range" do
      assert Nav.clamp(5, 0, 10) == 5
      assert Nav.clamp(0, 0, 10) == 0
      assert Nav.clamp(10, 0, 10) == 10
    end

    test "bounds a value outside the range to the nearest edge" do
      assert Nav.clamp(-3, 0, 10) == 0
      assert Nav.clamp(42, 0, 10) == 10
    end

    test "an inverted range collapses to the low bound" do
      # max(length - 1, 0) can't produce this, but the guards order lo first.
      assert Nav.clamp(5, 10, 0) == 10
    end
  end

  describe "clamp_index/2" do
    test "keeps an index that points into the list" do
      assert Nav.clamp_index(0, [:a, :b, :c]) == 0
      assert Nav.clamp_index(2, [:a, :b, :c]) == 2
    end

    test "pulls an out-of-range index back to the last row" do
      assert Nav.clamp_index(9, [:a, :b, :c]) == 2
      assert Nav.clamp_index(-1, [:a, :b, :c]) == 0
    end

    test "an emptied list clamps to 0, not -1" do
      # A cursor left over an emptied list must still name a renderable slot.
      assert Nav.clamp_index(3, []) == 0
      assert Nav.clamp_index(0, []) == 0
    end
  end

  describe "item_author/1" do
    test "prefers :author, as carried by enriched channel and search videos" do
      assert Nav.item_author(%{author: "Chris"}) == "Chris"
    end

    test "falls back to :channel, as stored on a bookmark" do
      assert Nav.item_author(%Bookmark{channel: "No Starch"}) == "No Starch"
      assert Nav.item_author(%{channel: "MIT"}) == "MIT"
    end

    test ":author wins when a row somehow carries both" do
      assert Nav.item_author(%{author: "Chris", channel: "MIT"}) == "Chris"
    end

    test "nil when neither key is present, as for a local file" do
      assert Nav.item_author(%{name: "clip.mkv"}) == nil
      assert Nav.item_author(%{author: nil, channel: nil}) == nil
    end
  end

  describe "playable_video/1" do
    test "builds the source-agnostic map the play and enqueue paths take" do
      video = %{title: "Elixir In Action", url: "https://youtu.be/abc", author: "Chris"}

      assert Nav.playable_video(video) == %{
               title: "Elixir In Action",
               url: "https://youtu.be/abc",
               local: false,
               author: "Chris"
             }
    end

    test "always marks the row remote — local files never reach this" do
      assert %{local: false} = Nav.playable_video(%{title: "t", url: "u"})
    end

    test "carries a nil author rather than omitting the key" do
      # The player omits its artist flag on nil; a missing key would crash it.
      assert %{author: nil} = Nav.playable_video(%{title: "t", url: "u"})
    end

    test "ignores the extra fields a video row carries" do
      video = %{title: "t", url: "u", author: "a", duration: 120, views: 4_000_000, live: :none}

      assert video |> Nav.playable_video() |> Map.keys() |> Enum.sort() ==
               [:author, :local, :title, :url]
    end
  end

  describe "page_step/0" do
    test "is a positive fixed step, since TUI state has no terminal height" do
      assert is_integer(Nav.page_step())
      assert Nav.page_step() > 0
    end
  end
end
