defmodule Playmark.TUI.FilterTest do
  use ExUnit.Case, async: true

  alias Playmark.TUI.Filter
  alias Playmark.{Bookmark, Subscription, Playlist}

  describe "matches?/3" do
    test "empty term matches everything" do
      assert Filter.matches?(%{title: "anything"}, [:title], "")
      assert Filter.matches?(%{title: nil}, [:title], "")
    end

    test "is a case-insensitive substring match" do
      row = %{title: "Elixir In Action"}
      assert Filter.matches?(row, [:title], "elixir")
      assert Filter.matches?(row, [:title], "ELIXIR")
      assert Filter.matches?(row, [:title], "in act")
      refute Filter.matches?(row, [:title], "erlang")
    end

    test "matches on any of the given fields" do
      row = %{title: "Some Video", channel: "MIT OpenCourseWare"}
      assert Filter.matches?(row, [:title, :channel], "mit")
      assert Filter.matches?(row, [:title, :channel], "video")
      refute Filter.matches?(row, [:title, :channel], "stanford")
    end

    test "non-binary or missing field values never match a non-empty term" do
      refute Filter.matches?(%{title: nil}, [:title], "x")
      refute Filter.matches?(%{title: 123}, [:title], "1")
      refute Filter.matches?(%{}, [:title], "x")
    end

    test "works uniformly on Ecto structs" do
      bookmark = %Bookmark{title: "Learn You Some Erlang", channel: "No Starch"}
      assert Filter.matches?(bookmark, [:title, :channel], "erlang")
      assert Filter.matches?(bookmark, [:title, :channel], "starch")
    end
  end

  describe "narrow/3" do
    test "empty term returns the list unchanged" do
      rows = [%{title: "a"}, %{title: "b"}]
      assert Filter.narrow(rows, [:title], "") == rows
    end

    test "keeps only matching rows" do
      rows = [%{title: "cats"}, %{title: "dogs"}, %{title: "cat food"}]
      assert Filter.narrow(rows, [:title], "cat") == [%{title: "cats"}, %{title: "cat food"}]
    end
  end

  describe "base_list/1 and fields/1 per view/mode" do
    test "videos mode uses the video list, matched on title" do
      videos = [%{title: "v1"}, %{title: "v2"}]
      state = %{mode: :videos, view: :subscriptions, videos: videos}
      assert Filter.base_list(state) == videos
      assert Filter.fields(state) == [:title]
    end

    test "bookmarks view uses bookmarks, matched on title + channel" do
      bookmarks = [%Bookmark{title: "b"}]
      state = %{mode: :list, view: :bookmarks, bookmarks: bookmarks}
      assert Filter.base_list(state) == bookmarks
      assert Filter.fields(state) == [:title, :channel]
    end

    test "subscriptions view uses subscriptions, matched on name + url" do
      subs = [%Subscription{name: "s", url: "u"}]
      state = %{mode: :list, view: :subscriptions, subscriptions: subs}
      assert Filter.base_list(state) == subs
      assert Filter.fields(state) == [:name, :url]
    end

    test "local view uses playlists, matched on name + path" do
      playlists = [%Playlist{name: "p", path: "/p"}]
      state = %{mode: :list, view: :local, playlists: playlists}
      assert Filter.base_list(state) == playlists
      assert Filter.fields(state) == [:name, :path]
    end

    test "search view has no list in :list mode" do
      state = %{mode: :list, view: :search}
      assert Filter.base_list(state) == []
      assert Filter.fields(state) == []
    end

    test "while the filter field is open, resolves through filter_return" do
      videos = [%{title: "v1"}]
      state = %{mode: :filter, filter_return: :videos, view: :subscriptions, videos: videos}
      assert Filter.base_list(state) == videos
      assert Filter.fields(state) == [:title]
    end
  end

  describe "visible/1" do
    test "narrows the base list by the active term" do
      videos = [%{title: "News Today"}, %{title: "Music Mix"}]
      state = %{mode: :videos, view: :search, videos: videos, filter: "news"}
      assert Filter.visible(state) == [%{title: "News Today"}]
    end

    test "an empty term returns the whole base list" do
      videos = [%{title: "a"}, %{title: "b"}]
      state = %{mode: :videos, view: :search, videos: videos, filter: ""}
      assert Filter.visible(state) == videos
    end

    test "tolerates a state without a :filter key" do
      bookmarks = [%Bookmark{title: "a"}]
      state = %{mode: :list, view: :bookmarks, bookmarks: bookmarks}
      assert Filter.visible(state) == bookmarks
    end
  end
end
