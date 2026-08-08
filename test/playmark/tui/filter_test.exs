defmodule Playmark.TUI.FilterTest do
  use ExUnit.Case, async: true

  alias Playmark.TUI.Filter
  alias Playmark.Bookmarks.Bookmark
  alias Playmark.Locals.Local
  alias Playmark.Playlists.Playlist
  alias Playmark.Subscriptions.Subscription

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

    test "local folders and files share title filtering in videos mode" do
      entries = [
        %{kind: :directory, title: "Season 1", path: "/v/Season 1"},
        %{kind: :file, title: "movie.mp4", url: "/v/movie.mp4"}
      ]

      state = %{mode: :videos, view: :locals, videos: entries, filter: "season"}
      assert Filter.visible(state) == [hd(entries)]
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

    test "playlists view uses playlists, matched on title + channel" do
      playlists = [%Playlist{title: "Course", channel: "Teacher"}]
      state = %{mode: :list, view: :playlists, playlists: playlists}
      assert Filter.base_list(state) == playlists
      assert Filter.fields(state) == [:title, :channel]
    end

    test "locals view uses locals, matched on name + path" do
      locals = [%Local{name: "p", path: "/p"}]
      state = %{mode: :list, view: :locals, locals: locals}
      assert Filter.base_list(state) == locals
      assert Filter.fields(state) == [:name, :path]
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
      state = %{mode: :videos, view: :subscriptions, videos: videos, filter: "news"}
      assert Filter.visible(state) == [%{title: "News Today"}]
    end

    test "an empty term returns the whole base list" do
      videos = [%{title: "a"}, %{title: "b"}]
      state = %{mode: :videos, view: :subscriptions, videos: videos, filter: ""}
      assert Filter.visible(state) == videos
    end

    test "tolerates a state without a :filter key" do
      bookmarks = [%Bookmark{title: "a"}]
      state = %{mode: :list, view: :bookmarks, bookmarks: bookmarks}
      assert Filter.visible(state) == bookmarks
    end
  end

  describe "visible_search/1" do
    test "filters isolated Search rows without using the base view" do
      state = %{
        view: :locals,
        search_videos: [%{title: "News Today"}, %{title: "Music Mix"}],
        search_filter: "news"
      }

      assert Filter.visible_search(state) == [%{title: "News Today"}]
    end
  end

  describe "visible_channel_playlists/1" do
    test "filters channel playlist containers independently" do
      state = %{
        channel_playlists: [%{title: "Elixir Course"}, %{title: "Music Mix"}],
        channel_playlist_filter: "elixir"
      }

      assert Filter.visible_channel_playlists(state) == [%{title: "Elixir Course"}]
    end
  end
end
