defmodule Playmark.TUITest.TestPlayback do
  @moduledoc """
  A stub player for the TUI's playback seam. `play/3` reports the `:playing`
  stage through the progress reporter (mirroring a real backend), tells the test
  process the task has started (handing it the task pid), then blocks until
  released with `:close`, modelling a real player that stays open until the user
  quits — so a test can observe the non-blocking `:playing` state before playback
  ends. `subtitles?/0` feeds the TUI's step plan.
  """

  def player, do: :test

  def subtitles?, do: false

  # The TUI passes a display meta map (%{title, author}) as the middle arg (see
  # start_play); the stub ignores it and behaves like a real backend advancing
  # to :playing.
  def play(_url, _meta, progress), do: announce_and_block(progress)

  # Local playback goes through play_local/3 instead of play/3; behave the same
  # so a test can observe the non-blocking :playing state for a local file too.
  def play_local(_path, _meta, progress), do: announce_and_block(progress)

  defp announce_and_block(progress) do
    progress.(:playing)

    test_pid = Application.get_env(:playmark, :test_playback_pid)
    send(test_pid, {__MODULE__, self()})

    receive do
      :close -> :ok
    after
      5_000 -> :ok
    end
  end
end

defmodule Playmark.TUITest.TestLocal do
  @moduledoc """
  A stub for the TUI's local-filesystem seam. `list_files/1` announces itself to
  the test process (handing it the task pid) and blocks until the test sends the
  files to return, so a test can observe the non-blocking `:loading` state before
  the list arrives — mirroring `TestChannel`.
  """

  def list_files(_dir) do
    test_pid = Application.get_env(:playmark, :test_local_pid)
    send(test_pid, {__MODULE__, self()})

    receive do
      {:files, files} -> {:ok, files}
    after
      5_000 -> {:ok, []}
    end
  end
end

defmodule Playmark.TUITest.TestChannel do
  @moduledoc """
  A stub for the TUI's channel seam. `list_videos/2` announces itself and the tab
  it was asked for to the test process (handing it the task pid) and blocks until
  the test sends the videos to return, so a test can observe the non-blocking
  `:loading` state before the list arrives, and assert which tab was fetched.
  `name/1` returns a fixed name without shelling out.
  """

  def name(_url), do: {:ok, "Stub Channel"}

  def list_videos(_url, tab \\ :videos) do
    test_pid = Application.get_env(:playmark, :test_channel_pid)
    send(test_pid, {__MODULE__, self(), tab})

    receive do
      {:videos, videos} -> {:ok, videos}
    after
      5_000 -> {:ok, []}
    end
  end
end

defmodule Playmark.TUITest.TestSearch do
  @moduledoc """
  A stub for the TUI's search seam. `search/1` announces itself to the test
  process (handing it the task pid) and blocks until the test sends the results
  to return, so a test can observe the non-blocking `:loading` state before the
  results arrive — mirroring `TestChannel`.
  """

  def search(_query, _limit \\ 20) do
    test_pid = Application.get_env(:playmark, :test_search_pid)
    send(test_pid, {__MODULE__, self()})

    receive do
      {:results, videos} -> {:ok, videos}
    after
      5_000 -> {:ok, []}
    end
  end
end

defmodule Playmark.TUITest do
  # test_mode disables live terminal polling; still touches the DB, so not async.
  use Playmark.DataCase, async: false

  alias Playmark.TUITest.TestChannel
  alias Playmark.TUITest.TestLocal
  alias Playmark.TUITest.TestPlayback
  alias Playmark.TUITest.TestSearch

  alias ExRatatui.Event
  alias ExRatatui.Runtime
  alias Playmark.{Bookmark, History, Queue, TUI}

  defp start_tui do
    {:ok, pid} = TUI.start_link(name: nil, test_mode: {80, 24})
    on_exit(fn -> if Process.alive?(pid), do: catch_exit(GenServer.stop(pid)) end)
    pid
  end

  defp press(pid, code) do
    :ok = Runtime.inject_event(pid, %Event.Key{code: code, kind: "press", modifiers: []})
  end

  defp type(pid, string) do
    for <<char::utf8 <- string>>, do: press(pid, <<char::utf8>>)
  end

  defp user_state(pid), do: :sys.get_state(pid).user_state

  test "renders with an empty bookmark list" do
    pid = start_tui()
    snapshot = Runtime.snapshot(pid)
    assert snapshot.render_count >= 1
  end

  test "starts in list mode" do
    assert user_state(start_tui()).mode == :list
  end

  test "j/k move the selection within bounds" do
    for i <- 1..3 do
      Repo.insert!(%Bookmark{url: "https://youtu.be/#{i}", title: "V#{i}", channel: "C"})
    end

    pid = start_tui()
    assert user_state(pid).selected == 0

    press(pid, "j")
    assert user_state(pid).selected == 1

    press(pid, "k")
    press(pid, "k")
    # clamped at the top
    assert user_state(pid).selected == 0

    press(pid, "j")
    press(pid, "j")
    press(pid, "j")
    press(pid, "j")
    # clamped at the last index (2)
    assert user_state(pid).selected == 2
  end

  test "q stops the runtime" do
    pid = start_tui()
    ref = Process.monitor(pid)
    press(pid, "q")
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
  end

  describe "status auto-clear" do
    test "a set status arms a one-shot clear timer carrying that status" do
      assert [%ExRatatui.Subscription{} = sub] =
               TUI.subscriptions(%{status: {:info, "Added: Foo"}})

      assert sub.id == :status_clear
      assert sub.kind == :once
      assert sub.message == {:clear_status, {:info, "Added: Foo"}}
    end

    test "a nil status arms no timer" do
      assert TUI.subscriptions(%{status: nil}) == []
    end

    test "the clear tick blanks the status it was armed for" do
      status = {:info, "Added: Foo"}
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | status: status}} end)

      send(pid, {:clear_status, status})
      _ = :sys.get_state(pid)

      assert user_state(pid).status == nil
    end

    test "a clear tick for a stale status leaves a newer one intact" do
      pid = start_tui()
      newer = {:error, "Something else"}
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | status: newer}} end)

      # A tick armed for an earlier status arrives late; it must not wipe `newer`.
      send(pid, {:clear_status, {:info, "Added: Foo"}})
      _ = :sys.get_state(pid)

      assert user_state(pid).status == newer
    end
  end

  describe "delete confirmation" do
    test "d stages a confirmation instead of deleting immediately" do
      Repo.insert!(%Bookmark{url: "https://youtu.be/x", title: "Keeper", channel: "C"})
      pid = start_tui()

      press(pid, "d")

      state = user_state(pid)
      assert state.mode == :confirm
      # Nothing deleted yet — the row is still there.
      assert length(state.bookmarks) == 1
    end

    test "y confirms the delete and returns to list mode" do
      Repo.insert!(%Bookmark{url: "https://youtu.be/x", title: "Doomed", channel: "C"})
      pid = start_tui()

      press(pid, "d")
      press(pid, "y")

      state = user_state(pid)
      assert state.mode == :list
      assert state.bookmarks == []
      assert {:info, "Deleted"} = state.status
    end

    test "n cancels the delete, leaving the item intact" do
      Repo.insert!(%Bookmark{url: "https://youtu.be/x", title: "Keeper", channel: "C"})
      pid = start_tui()

      press(pid, "d")
      press(pid, "n")

      state = user_state(pid)
      assert state.mode == :list
      assert length(state.bookmarks) == 1
      assert {:info, "Canceled"} = state.status
    end

    test "any non-y key cancels the delete" do
      Repo.insert!(%Bookmark{url: "https://youtu.be/x", title: "Keeper", channel: "C"})
      pid = start_tui()

      press(pid, "d")
      press(pid, "esc")

      state = user_state(pid)
      assert state.mode == :list
      assert length(state.bookmarks) == 1
    end

    test "d with an empty list is a no-op (no confirmation staged)" do
      pid = start_tui()

      press(pid, "d")

      assert user_state(pid).mode == :list
    end
  end

  describe "add-bookmark flow" do
    test "\"a\" enters input mode and typing updates the field" do
      pid = start_tui()

      press(pid, "a")
      assert user_state(pid).mode == :input

      type(pid, "hello")
      assert ExRatatui.text_input_get_value(user_state(pid).input) == "hello"
    end

    test "pasting a URL inserts it into the field" do
      pid = start_tui()

      press(pid, "a")
      :ok = Runtime.inject_event(pid, %Event.Paste{content: "https://youtu.be/xyz"})
      _ = :sys.get_state(pid)

      assert ExRatatui.text_input_get_value(user_state(pid).input) == "https://youtu.be/xyz"
    end

    test "paste is ignored outside input mode" do
      pid = start_tui()

      :ok = Runtime.inject_event(pid, %Event.Paste{content: "junk"})
      _ = :sys.get_state(pid)

      assert user_state(pid).mode == :list
    end

    test "esc cancels back to list mode without saving" do
      pid = start_tui()

      press(pid, "a")
      type(pid, "https://youtu.be/abc")
      press(pid, "esc")

      assert user_state(pid).mode == :list
      assert Playmark.Bookmarks.list_bookmarks() == []
    end

    test "\"a\" clears any text left over from a previous attempt" do
      pid = start_tui()

      press(pid, "a")
      type(pid, "stale")
      press(pid, "esc")
      press(pid, "a")

      assert ExRatatui.text_input_get_value(user_state(pid).input) == ""
    end

    test "in list mode, letter keys other than bindings are ignored" do
      pid = start_tui()
      # "z" is not a binding; must not enter input mode or crash.
      press(pid, "z")
      assert user_state(pid).mode == :list
    end

    test "Enter with an empty field stays in input mode with an error" do
      pid = start_tui()

      press(pid, "a")
      press(pid, "enter")

      state = user_state(pid)
      assert state.mode == :input
      assert {:error, _} = state.status
    end

    test "keys are ignored while fetching" do
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :fetching}} end)

      press(pid, "a")
      press(pid, "j")
      assert user_state(pid).mode == :fetching
    end

    test "esc cancels a fetch back to list mode" do
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :fetching}} end)

      press(pid, "esc")

      assert user_state(pid).mode == :list
    end

    test "a result that arrives after cancel is dropped" do
      pid = start_tui()
      # Simulate: user canceled, so we're back in list mode, then the in-flight
      # task's result lands late. It must not yank the user back into the flow.
      send(pid, {:add_result, {:error, "too late"}})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :list
      assert state.status == nil
    end

    test "a successful add result returns to list mode and refreshes" do
      pid = start_tui()
      bookmark = Repo.insert!(%Bookmark{url: "https://youtu.be/ok", title: "Done", channel: "C"})
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :fetching}} end)

      send(pid, {:add_result, {:ok, bookmark}})
      # Give handle_info a moment to run.
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :list
      assert state.selected == 0
      assert {:info, "Added: Done"} = state.status
      assert length(state.bookmarks) == 1
    end

    test "an error result returns to input mode so the user can retry" do
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :fetching}} end)

      send(pid, {:add_result, {:error, "video unavailable"}})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :input
      assert {:error, "video unavailable"} = state.status
    end

    test "a duplicate bookmark shows a friendly message, not raw Ecto text" do
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :fetching}} end)

      send(pid, {:add_result, {:error, duplicate_bookmark_changeset()}})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :input
      assert {:error, "Already bookmarked"} = state.status
    end

    test "a duplicate subscription shows a channel-specific message" do
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :fetching}} end)

      send(pid, {:add_result, {:error, duplicate_subscription_changeset()}, :subscription})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :input
      assert {:error, "Already subscribed to this channel"} = state.status
    end

    test "a duplicate local directory shows a directory-specific message" do
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :fetching}} end)

      send(pid, {:add_result, {:error, duplicate_playlist_changeset()}, :playlist})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :input
      assert {:error, "Directory already registered"} = state.status
    end
  end

  describe "playback flow" do
    test "Enter on a bookmark enters :playing mode without blocking" do
      # Stub the player so the suite never spawns a real vlc/mpv or hits the
      # network. The stub blocks until released, modelling a player the user
      # hasn't closed yet, so we can observe the non-blocking :playing state.
      test_pid = self()
      Application.put_env(:playmark, :playback_impl, TestPlayback)
      Application.put_env(:playmark, :test_playback_pid, test_pid)
      on_exit(fn -> Application.delete_env(:playmark, :playback_impl) end)

      Repo.insert!(%Bookmark{url: "https://youtu.be/play", title: "V", channel: "C"})
      pid = start_tui()

      press(pid, "enter")

      # The runtime must return immediately (playback runs in a task), so this
      # call would time out if handle_event were blocked on the player.
      state = user_state(pid)
      assert state.mode == :playing
      # The step-by-step panel is seeded from the selected item and player; the
      # status line is cleared since the panel now carries the detail.
      assert state.status == nil
      assert %{title: "V", player: :test, steps: steps} = state.playing
      assert :playing in steps

      # Release the stubbed player so its task can finish cleanly.
      assert_receive {TestPlayback, play_task}, 1_000
      send(play_task, :close)
    end

    test "Enter with no bookmarks stays in list mode" do
      pid = start_tui()
      press(pid, "enter")
      assert user_state(pid).mode == :list
    end

    test "keys are ignored while playing" do
      Repo.insert!(%Bookmark{url: "https://youtu.be/play", title: "V", channel: "C"})
      pid = start_tui()

      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :playing}} end)

      press(pid, "a")
      press(pid, "j")
      press(pid, "q")
      assert user_state(pid).mode == :playing
    end

    test "a successful play result returns to list mode" do
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :playing}} end)

      send(pid, {:play_result, :ok})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :list
      assert state.status == nil
    end

    test "a failed play result returns to list mode with an error" do
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :playing}} end)

      send(pid, {:play_result, {:error, "vlc exited with 1"}})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :list
      assert {:error, "Playback failed: vlc exited with 1"} = state.status
    end
  end

  describe "subscriptions view" do
    setup do
      Application.put_env(:playmark, :channel_impl, TestChannel)
      Application.put_env(:playmark, :test_channel_pid, self())

      on_exit(fn ->
        Application.delete_env(:playmark, :channel_impl)
        Application.delete_env(:playmark, :test_channel_pid)
      end)
    end

    defp insert_sub(url, name) do
      Repo.insert!(%Playmark.Subscription{url: url, name: name})
    end

    test "Tab cycles bookmarks -> subscriptions -> search -> local -> bookmarks" do
      pid = start_tui()
      assert user_state(pid).view == :bookmarks

      press(pid, "tab")
      assert user_state(pid).view == :subscriptions

      press(pid, "tab")
      assert user_state(pid).view == :search

      press(pid, "tab")
      assert user_state(pid).view == :local

      press(pid, "tab")
      assert user_state(pid).view == :bookmarks
    end

    test "Tab resets selection and clears status" do
      insert_sub("https://youtube.com/@a/videos", "A")
      pid = start_tui()

      :sys.replace_state(pid, fn s ->
        %{s | user_state: %{s.user_state | selected: 2, status: {:info, "stale"}}}
      end)

      press(pid, "tab")
      state = user_state(pid)
      assert state.selected == 0
      assert state.status == nil
    end

    test "Enter on a subscription enters :loading without blocking" do
      insert_sub("https://youtube.com/@a/videos", "Channel A")
      pid = start_tui()

      press(pid, "tab")
      press(pid, "enter")

      state = user_state(pid)
      assert state.mode == :loading
      assert {:info, _} = state.status

      # The task called the stub, which announced itself and blocks.
      assert_receive {TestChannel, task, :videos}, 1_000
      send(task, {:videos, [%{id: "x", title: "Vid X", url: "https://youtu.be/x"}]})
    end

    test "a videos_result populates the video list and enters :videos mode" do
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :loading}} end)

      videos = [%{id: "x", title: "Vid X", url: "https://youtu.be/x"}]
      send(pid, {:videos_result, {:ok, videos}, "Channel A", "https://youtube.com/@a", :videos})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :videos
      assert state.videos == videos
      assert state.channel_name == "Channel A"
      assert state.channel_url == "https://youtube.com/@a"
      assert state.video_tab == :videos
    end

    test "a videos_result error returns to list mode" do
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :loading}} end)

      send(
        pid,
        {:videos_result, {:error, "yt-dlp failed"}, "Channel A", "https://youtube.com/@a",
         :videos}
      )

      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :list
      assert {:error, _} = state.status
    end

    test "Esc cancels a stuck :loading back to list" do
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :loading}} end)

      press(pid, "esc")
      assert user_state(pid).mode == :list
    end

    test "a late videos_result after cancel is dropped" do
      pid = start_tui()
      # mode is :list (canceled), not :loading
      send(
        pid,
        {:videos_result, {:ok, [%{id: "x", title: "X", url: "u"}]}, "A", "https://youtube.com/@a",
         :videos}
      )

      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :list
      assert state.videos == []
    end

    test "Esc from :videos returns to the list it was opened from" do
      pid = start_tui()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | view: :subscriptions,
                mode: :videos,
                videos: [%{id: "x", title: "X", url: "u"}],
                channel_name: "A"
            }
        }
      end)

      press(pid, "esc")
      state = user_state(pid)
      assert state.mode == :list
      assert state.view == :subscriptions
      assert state.videos == []
    end

    test "s from a subscription :videos listing re-fetches the streams tab" do
      pid = start_tui()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | view: :subscriptions,
                mode: :videos,
                videos: [%{id: "x", title: "Vid X", url: "u", live: :none}],
                channel_name: "Channel A",
                channel_url: "https://youtube.com/@a",
                video_tab: :videos
            }
        }
      end)

      press(pid, "s")

      # The switch drops into :loading and the stub is asked for the :streams tab.
      assert user_state(pid).mode == :loading
      assert_receive {TestChannel, task, :streams}, 1_000

      streams = [%{id: "s1", title: "Live Now", url: "u1", live: :live}]
      send(task, {:videos, streams})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :videos
      assert state.video_tab == :streams
      assert state.videos == streams
    end

    test "v flips a streams listing back to the videos tab" do
      pid = start_tui()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | view: :subscriptions,
                mode: :videos,
                videos: [%{id: "s1", title: "Live", url: "u", live: :live}],
                channel_name: "Channel A",
                channel_url: "https://youtube.com/@a",
                video_tab: :streams
            }
        }
      end)

      press(pid, "v")

      assert user_state(pid).mode == :loading
      assert_receive {TestChannel, task, :videos}, 1_000
      send(task, {:videos, [%{id: "x", title: "Upload", url: "u2", live: :none}]})
      _ = :sys.get_state(pid)

      assert user_state(pid).video_tab == :videos
    end

    test "s on the current tab is a no-op (no re-fetch)" do
      pid = start_tui()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | view: :subscriptions,
                mode: :videos,
                videos: [%{id: "s1", title: "Live", url: "u", live: :live}],
                channel_name: "Channel A",
                channel_url: "https://youtube.com/@a",
                video_tab: :streams
            }
        }
      end)

      press(pid, "s")

      # Already on :streams — stays in :videos, never enters :loading, no stub call.
      assert user_state(pid).mode == :videos
      refute_receive {TestChannel, _task, _tab}, 200
    end

    test "on a subscription listing keeps the current list when a tab switch fails" do
      pid = start_tui()

      videos = [%{id: "x", title: "Vid X", url: "u", live: :none}]

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | view: :subscriptions,
                mode: :loading,
                videos: videos,
                channel_name: "Channel A",
                channel_url: "https://youtube.com/@a",
                video_tab: :videos
            }
        }
      end)

      send(
        pid,
        {:videos_result, {:error, "yt-dlp failed"}, "Channel A", "https://youtube.com/@a",
         :streams}
      )

      _ = :sys.get_state(pid)

      state = user_state(pid)
      # Error surfaced, but the previously-shown list stays on screen.
      assert state.mode == :videos
      assert state.videos == videos
      assert {:error, _} = state.status
    end

    test "b in :videos mode bookmarks the selected video" do
      pid = start_tui()

      video = %{id: "x", title: "Vid X", url: "https://youtu.be/x"}

      :sys.replace_state(pid, fn s ->
        %{s | user_state: %{s.user_state | mode: :videos, videos: [video], channel_name: "A"}}
      end)

      # The bookmark runs in a task hitting the real Bookmarks.add_bookmark, which
      # would need the network. Instead, drive the result message directly.
      send(pid, {:bookmark_video_result, {:ok, %Bookmark{title: "Vid X"}}})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      # Still browsing videos; only the status reflects the bookmark.
      assert state.mode == :videos
      assert {:info, "Bookmarked: Vid X"} = state.status
    end

    # Regression: pressing Enter to play a video sets mode: :playing. The body
    # shows the "Now playing" panel, and the header keeps the channel context —
    # neither must flip to the subscriptions list underneath the player.
    test "while playing a video from the list, the body shows the now-playing panel" do
      video = %{id: "x", title: "Vid X", url: "https://youtu.be/x"}

      state = %{
        view: :subscriptions,
        mode: :playing,
        bookmarks: [],
        subscriptions: [%Playmark.Subscription{url: "u", name: "Chan A"}],
        videos: [video],
        channel_name: "Chan A",
        selected: 0,
        input: nil,
        playing: %{title: "Vid X", player: :mpv, steps: [:captions, :playing], stage: :captions},
        status: nil
      }

      widgets = TUI.render(state, %ExRatatui.Frame{width: 80, height: 24})
      titles = block_titles(widgets)

      assert Enum.member?(titles, " Now playing ")
      refute Enum.member?(titles, " Subscriptions ")
    end
  end

  describe "search view" do
    setup do
      Application.put_env(:playmark, :search_impl, TestSearch)
      Application.put_env(:playmark, :test_search_pid, self())

      on_exit(fn ->
        Application.delete_env(:playmark, :search_impl)
        Application.delete_env(:playmark, :test_search_pid)
      end)
    end

    defp to_search(pid) do
      # Cycle Tab to the search view: bookmarks -> subscriptions -> search.
      press(pid, "tab")
      press(pid, "tab")
      assert user_state(pid).view == :search
    end

    test "\"a\" does not open the prompt in search; \"/\" does" do
      pid = start_tui()
      to_search(pid)

      # "a" adds in the other views but is inert here.
      press(pid, "a")
      assert user_state(pid).mode == :list

      press(pid, "/")
      assert user_state(pid).mode == :input
    end

    test "submitting a query enters :loading without blocking" do
      pid = start_tui()
      to_search(pid)

      press(pid, "/")
      type(pid, "today's news")
      press(pid, "enter")

      state = user_state(pid)
      assert state.mode == :loading
      assert {:info, _} = state.status

      # The task called the stub, which announced itself and blocks.
      assert_receive {TestSearch, task}, 1_000
      send(task, {:results, [%{id: "x", title: "Vid X", url: "https://youtu.be/x"}]})
    end

    test "a search_result populates the video list and enters :videos mode" do
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :loading}} end)

      videos = [%{id: "x", title: "Vid X", url: "https://youtu.be/x"}]
      send(pid, {:search_result, {:ok, videos}, "today's news"})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :videos
      assert state.videos == videos
      # The query stands in for the channel-name label.
      assert state.channel_name == "today's news"
      assert {:info, "1 results for today's news"} = state.status
      # A search listing has no channel URL, so s/v can't switch tabs on it.
      assert state.channel_url == nil
    end

    test "s is a no-op on a search listing (no channel_url to switch)" do
      pid = start_tui()

      videos = [%{id: "x", title: "Vid X", url: "u"}]

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | view: :search,
                mode: :videos,
                videos: videos,
                channel_name: "today's news",
                channel_url: nil,
                video_tab: :videos
            }
        }
      end)

      press(pid, "s")

      state = user_state(pid)
      # Stays put: no channel URL means no tab to fetch.
      assert state.mode == :videos
      assert state.videos == videos
      assert state.video_tab == :videos
    end

    test "an empty search_result reports no results but still enters :videos mode" do
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :loading}} end)

      send(pid, {:search_result, {:ok, []}, "obscure query"})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :videos
      assert {:info, "No results for obscure query"} = state.status
    end

    test "a search_result error returns to list mode" do
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :loading}} end)

      send(pid, {:search_result, {:error, "yt-dlp failed"}, "q"})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :list
      assert {:error, "Search failed: yt-dlp failed"} = state.status
    end

    test "a late search_result after cancel is dropped" do
      pid = start_tui()
      # mode is :list (canceled), not :loading
      send(pid, {:search_result, {:ok, [%{id: "x", title: "X", url: "u"}]}, "q"})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :list
      assert state.videos == []
    end

    test "Esc from search results returns to the search view" do
      pid = start_tui()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | view: :search,
                mode: :videos,
                videos: [%{id: "x", title: "X", url: "u"}],
                channel_name: "today's news"
            }
        }
      end)

      press(pid, "esc")
      state = user_state(pid)
      assert state.mode == :list
      assert state.view == :search
      assert state.videos == []
    end

    test "search results render under a \"Search results\" title, not \"Latest videos\"" do
      state = %{
        view: :search,
        mode: :videos,
        bookmarks: [],
        subscriptions: [],
        videos: [%{id: "x", title: "Vid X", url: "u"}],
        channel_name: "gustixa",
        selected: 0,
        input: nil,
        status: {:info, "1 results for gustixa"}
      }

      titles = block_titles(TUI.render(state, %ExRatatui.Frame{width: 80, height: 24}))

      assert Enum.member?(titles, " Search results ")
      refute Enum.member?(titles, " Latest videos ")
    end

    test "the streams tab renders a Status column with live badges" do
      state = %{
        view: :subscriptions,
        mode: :videos,
        bookmarks: [],
        subscriptions: [],
        videos: [
          %{id: "a", title: "Live Now", url: "u1", live: :live},
          %{id: "b", title: "Past Stream", url: "u2", live: :ended},
          %{id: "c", title: "Scheduled", url: "u3", live: :upcoming},
          %{id: "d", title: "Plain Upload", url: "u4", live: :none}
        ],
        channel_name: "Channel A",
        channel_url: "https://youtube.com/@a",
        video_tab: :streams,
        selected: 0,
        input: nil,
        status: nil
      }

      widgets = TUI.render(state, %ExRatatui.Frame{width: 80, height: 24})
      titles = block_titles(widgets)
      rows = table_rows(widgets)

      # The panel is titled "Streams", and each row carries its status badge.
      assert Enum.member?(titles, " Streams ")
      assert Enum.member?(rows, ["Live Now", "LIVE"])
      assert Enum.member?(rows, ["Past Stream", "ENDED"])
      assert Enum.member?(rows, ["Scheduled", "SOON"])
      # A regular upload on the streams tab shows a blank badge, not a label.
      assert Enum.member?(rows, ["Plain Upload", ""])
    end

    test "the videos tab renders a single Title column (no Status badges)" do
      state = %{
        view: :subscriptions,
        mode: :videos,
        bookmarks: [],
        subscriptions: [],
        videos: [%{id: "a", title: "Some Video", url: "u1", live: :none}],
        channel_name: "Channel A",
        channel_url: "https://youtube.com/@a",
        video_tab: :videos,
        selected: 0,
        input: nil,
        status: nil
      }

      widgets = TUI.render(state, %ExRatatui.Frame{width: 80, height: 24})
      assert Enum.member?(block_titles(widgets), " Videos ")
      assert Enum.member?(table_rows(widgets), ["Some Video"])
    end
  end

  describe "local view" do
    setup do
      Application.put_env(:playmark, :local_impl, TestLocal)
      Application.put_env(:playmark, :test_local_pid, self())

      on_exit(fn ->
        Application.delete_env(:playmark, :local_impl)
        Application.delete_env(:playmark, :test_local_pid)
      end)
    end

    defp to_local(pid) do
      # bookmarks -> subscriptions -> search -> local
      press(pid, "tab")
      press(pid, "tab")
      press(pid, "tab")
      assert user_state(pid).view == :local
    end

    defp insert_playlist(path, name) do
      Repo.insert!(%Playmark.Playlist{path: path, name: name})
    end

    test "\"a\" opens the register prompt with a path placeholder" do
      pid = start_tui()
      to_local(pid)

      press(pid, "a")
      assert user_state(pid).mode == :input
    end

    test "Enter on a playlist enters :loading without blocking" do
      insert_playlist("/tmp/videos", "videos")
      pid = start_tui()
      to_local(pid)

      press(pid, "enter")

      state = user_state(pid)
      assert state.mode == :loading
      assert {:info, _} = state.status

      # The task called the stub, which announced itself and blocks.
      assert_receive {TestLocal, task}, 1_000
      send(task, {:files, [%{id: "/tmp/videos/a.mp4", title: "a.mp4", url: "/tmp/videos/a.mp4"}]})
    end

    test "a files_result populates the video list and enters :videos mode" do
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :loading}} end)

      files = [%{id: "/tmp/v/a.mp4", title: "a.mp4", url: "/tmp/v/a.mp4"}]
      send(pid, {:files_result, {:ok, files}, "videos"})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :videos
      assert state.videos == files
      assert state.channel_name == "videos"
      assert {:info, "1 files in videos"} = state.status
    end

    test "an empty files_result reports no media but still enters :videos mode" do
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :loading}} end)

      send(pid, {:files_result, {:ok, []}, "empty"})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :videos
      assert {:info, "No media files in empty"} = state.status
    end

    test "a files_result error returns to list mode" do
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :loading}} end)

      send(pid, {:files_result, {:error, "could not read /x"}, "x"})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :list
      assert {:error, _} = state.status
    end

    test "a late files_result after cancel is dropped" do
      pid = start_tui()
      # mode is :list (canceled), not :loading
      send(pid, {:files_result, {:ok, [%{id: "a", title: "a", url: "a"}]}, "v"})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :list
      assert state.videos == []
    end

    test "a successful playlist add result switches to the local view and refreshes" do
      pid = start_tui()
      playlist = insert_playlist("/tmp/added", "added")
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :fetching}} end)

      send(pid, {:add_result, {:ok, playlist}, :playlist})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.view == :local
      assert state.mode == :list
      assert {:info, "Added: added"} = state.status
      assert length(state.playlists) == 1
    end

    test "Enter on a local file plays via play_local without blocking" do
      test_pid = self()
      Application.put_env(:playmark, :playback_impl, TestPlayback)
      Application.put_env(:playmark, :test_playback_pid, test_pid)
      on_exit(fn -> Application.delete_env(:playmark, :playback_impl) end)

      pid = start_tui()
      file = %{id: "/tmp/v/a.mp4", title: "a.mp4", url: "/tmp/v/a.mp4"}

      :sys.replace_state(pid, fn s ->
        %{s | user_state: %{s.user_state | view: :local, mode: :videos, videos: [file]}}
      end)

      press(pid, "enter")
      assert user_state(pid).mode == :playing

      # play_local/1 on the stub announced itself; release it.
      assert_receive {TestPlayback, play_task}, 1_000
      send(play_task, :close)
    end

    test "b in :videos mode is a no-op for local files (can't bookmark)" do
      pid = start_tui()
      file = %{id: "/tmp/v/a.mp4", title: "a.mp4", url: "/tmp/v/a.mp4"}

      :sys.replace_state(pid, fn s ->
        %{s | user_state: %{s.user_state | view: :local, mode: :videos, videos: [file]}}
      end)

      press(pid, "b")
      state = user_state(pid)
      assert state.mode == :videos
      assert {:info, "Bookmarking is for YouTube videos only"} = state.status
      assert Playmark.Bookmarks.list_bookmarks() == []
    end

    test "local file list renders under a \"Files\" title" do
      state = %{
        view: :local,
        mode: :videos,
        bookmarks: [],
        subscriptions: [],
        playlists: [],
        videos: [%{id: "/tmp/v/a.mp4", title: "a.mp4", url: "/tmp/v/a.mp4"}],
        channel_name: "videos",
        selected: 0,
        input: nil,
        status: {:info, "1 files in videos"}
      }

      titles = block_titles(TUI.render(state, %ExRatatui.Frame{width: 80, height: 24}))

      assert Enum.member?(titles, " Files ")
      refute Enum.member?(titles, " Latest videos ")
    end
  end

  describe "now playing panel" do
    # A state in :playing mode with a seeded playing map, as Actions.start_play
    # builds it. `stage` is which step the backend has most recently reported;
    # `captions` carries the configured default/fallback plus the resolved result
    # (nil until the backend reports it); `stream` carries the quality cap plus the
    # resolved shape (nil until VLC reports).
    defp playing_state(stage, steps, opts \\ []) do
      captions = Keyword.get(opts, :captions, %{default: "en", fallback: nil, result: nil})
      stream = Keyword.get(opts, :stream, %{max_height: 1080, result: nil})

      %{
        view: :bookmarks,
        mode: :playing,
        bookmarks: [],
        subscriptions: [],
        playlists: [],
        videos: [],
        channel_name: nil,
        selected: 0,
        input: nil,
        status: nil,
        playing: %{
          title: "Some Video",
          player: :vlc,
          steps: steps,
          stage: stage,
          captions: captions,
          stream: stream
        }
      }
    end

    test "shows the title, player, and a checklist of the play's steps" do
      widgets = TUI.render(playing_state(:captions, [:captions, :playing]), frame())
      body = body_text(widgets)

      assert body =~ "Some Video"
      assert body =~ "in vlc"
      assert body =~ "Captions"
      assert body =~ "Playing"
      assert Enum.member?(block_titles(widgets), " Now playing ")
    end

    test "marks earlier steps done, the current step active, later steps pending" do
      steps = [:resolving, :captions, :playing]
      body = body_text(TUI.render(playing_state(:captions, steps), frame()))

      # resolving already happened, captions is in progress, playing is pending.
      assert body =~ "[done       ] Resolving stream"
      assert body =~ "[in progress] Captions"
      assert body =~ "[waiting    ] Playing"
    end

    test "before any stage is reported, every step is pending" do
      steps = [:resolving, :captions, :playing]
      body = body_text(TUI.render(playing_state(:starting, steps), frame()))

      assert body =~ "Resolving stream"
      assert body =~ "Captions"
      assert body =~ "Playing"
      # Nothing is in progress or done yet — every step reads as waiting.
      refute body =~ "[in progress]"
      refute body =~ "[done"
    end

    test "the caption step shows the target language and fallback before resolving" do
      caps = %{default: "en", fallback: "id", result: nil}

      body =
        body_text(
          TUI.render(playing_state(:captions, [:captions, :playing], captions: caps), frame())
        )

      assert body =~ "Captions — seeking en, fallback id"
    end

    test "the caption step names a resolved uploader track with its language" do
      caps = %{default: "en", fallback: nil, result: {:manual, "en-US"}}

      body =
        body_text(
          TUI.render(playing_state(:playing, [:captions, :playing], captions: caps), frame())
        )

      assert body =~ "Captions — en-US, uploader-provided"
    end

    test "the caption step names a resolved auto-generated track with its language" do
      caps = %{default: "en", fallback: nil, result: {:auto, "id-orig"}}

      body =
        body_text(
          TUI.render(playing_state(:playing, [:captions, :playing], captions: caps), frame())
        )

      assert body =~ "Captions — id-orig, auto-generated"
    end

    test "the caption step reports when no track matched" do
      caps = %{default: "en", fallback: nil, result: :none}

      body =
        body_text(
          TUI.render(playing_state(:playing, [:captions, :playing], captions: caps), frame())
        )

      assert body =~ "Captions — none available"
    end

    test "the stream step shows the quality cap before resolving" do
      strm = %{max_height: 720, result: nil}

      body =
        body_text(
          TUI.render(playing_state(:resolving, [:resolving, :playing], stream: strm), frame())
        )

      assert body =~ "Resolving stream — up to 720p"
    end

    test "the stream step names a resolved split video+audio rendition" do
      strm = %{max_height: 1080, result: :split}

      body =
        body_text(
          TUI.render(playing_state(:playing, [:resolving, :playing], stream: strm), frame())
        )

      assert body =~ "Resolving stream — 1080p cap, video+audio"
    end

    test "the stream step names a resolved muxed rendition" do
      strm = %{max_height: 1080, result: :muxed}

      body =
        body_text(
          TUI.render(playing_state(:playing, [:resolving, :playing], stream: strm), frame())
        )

      assert body =~ "Resolving stream — 1080p cap, muxed"
    end

    test "a :stream result folds into the playing map and stays on the resolving stage" do
      pid = start_tui()

      :sys.replace_state(pid, fn s ->
        playing = %{
          title: "V",
          player: :vlc,
          steps: [:resolving, :playing],
          stage: :resolving,
          captions: %{default: "en", fallback: nil, result: nil},
          stream: %{max_height: 1080, result: nil}
        }

        %{s | user_state: %{s.user_state | mode: :playing, playing: playing}}
      end)

      send(pid, {:play_progress, {:stream, :split}})
      _ = :sys.get_state(pid)

      playing = user_state(pid).playing
      # The concrete shape is recorded; the stage marker is unchanged.
      assert playing.stream.result == :split
      assert playing.stage == :resolving
    end

    test "a :play_progress message advances the stage in state" do
      pid = start_tui()

      :sys.replace_state(pid, fn s ->
        playing = %{
          title: "V",
          player: :mpv,
          steps: [:captions, :playing],
          stage: :starting,
          captions: %{default: "en", fallback: nil, result: nil}
        }

        %{s | user_state: %{s.user_state | mode: :playing, playing: playing}}
      end)

      send(pid, {:play_progress, :captions})
      _ = :sys.get_state(pid)

      assert user_state(pid).playing.stage == :captions
    end

    test "a :caption result folds into the playing map and stays on the captions stage" do
      pid = start_tui()

      :sys.replace_state(pid, fn s ->
        playing = %{
          title: "V",
          player: :mpv,
          steps: [:captions, :playing],
          stage: :captions,
          captions: %{default: "en", fallback: nil, result: nil}
        }

        %{s | user_state: %{s.user_state | mode: :playing, playing: playing}}
      end)

      send(pid, {:play_progress, {:caption, {:auto, "id"}}})
      _ = :sys.get_state(pid)

      playing = user_state(pid).playing
      # The concrete result is recorded; the stage marker is unchanged.
      assert playing.captions.result == {:auto, "id"}
      assert playing.stage == :captions
    end

    test "a :play_progress message is dropped once no longer playing" do
      pid = start_tui()
      # mode :list (the default) — a late stage from a finished play must not crash
      # or mutate state.
      send(pid, {:play_progress, :playing})
      _ = :sys.get_state(pid)

      assert user_state(pid).mode == :list
    end
  end

  describe "queue" do
    setup do
      Application.put_env(:playmark, :playback_impl, TestPlayback)
      Application.put_env(:playmark, :test_playback_pid, self())

      on_exit(fn ->
        Application.delete_env(:playmark, :playback_impl)
        Application.delete_env(:playmark, :test_playback_pid)
      end)
    end

    test "e appends the selected bookmark to the queue, carrying local?: false" do
      Repo.insert!(%Bookmark{url: "https://youtu.be/a", title: "A", channel: "C"})
      pid = start_tui()

      press(pid, "e")

      state = user_state(pid)
      assert [item] = state.queue
      assert item.title == "A"
      assert item.local == false
      assert {:info, "Queued: A"} = state.status
    end

    test "e on a local file queues it with local?: true" do
      # Drive the local view to a populated video list via the stub, then queue.
      Application.put_env(:playmark, :local_impl, TestLocal)
      Application.put_env(:playmark, :test_local_pid, self())

      on_exit(fn ->
        Application.delete_env(:playmark, :local_impl)
        Application.delete_env(:playmark, :test_local_pid)
      end)

      pid = start_tui()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | view: :local,
                mode: :videos,
                videos: [%{title: "clip.mp4", url: "/home/vids/clip.mp4"}],
                selected: 0
            }
        }
      end)

      press(pid, "e")

      assert [item] = user_state(pid).queue
      assert item.url == "/home/vids/clip.mp4"
      assert item.local == true
    end

    test "e with nothing selectable is a no-op" do
      # Search view holds no list in :list mode.
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | view: :search}} end)

      press(pid, "e")
      assert user_state(pid).queue == []
    end

    test "Q opens the queue-manage modal and Esc restores the prior mode" do
      pid = start_tui()
      assert user_state(pid).mode == :list

      press(pid, "Q")
      state = user_state(pid)
      assert state.mode == :queue_manage
      assert state.queue_return == :list

      press(pid, "esc")
      assert user_state(pid).mode == :list
    end

    test "Q can be opened over the running player and Esc returns to :playing" do
      Repo.insert!(%Bookmark{url: "https://youtu.be/a", title: "A", channel: "C"})
      pid = start_tui()
      press(pid, "enter")
      assert user_state(pid).mode == :playing
      assert_receive {TestPlayback, play_task}, 1_000

      press(pid, "Q")
      assert user_state(pid).mode == :queue_manage
      assert user_state(pid).queue_return == :playing

      press(pid, "esc")
      assert user_state(pid).mode == :playing

      send(play_task, :close)
    end

    test "j/k navigate within the modal, clamped to the queue bounds" do
      Enum.each(["A", "B", "C"], fn t ->
        {:ok, _} = Queue.enqueue(%{title: t, url: "u-#{t}", local: false})
      end)

      pid = start_tui()
      press(pid, "Q")
      assert user_state(pid).queue_selected == 0

      press(pid, "k")
      assert user_state(pid).queue_selected == 0

      press(pid, "j")
      press(pid, "j")
      assert user_state(pid).queue_selected == 2

      press(pid, "j")
      assert user_state(pid).queue_selected == 2
    end

    test "] moves the selected item down and keeps the cursor on it" do
      Enum.each(["A", "B", "C"], fn t ->
        {:ok, _} = Queue.enqueue(%{title: t, url: "u-#{t}", local: false})
      end)

      pid = start_tui()
      press(pid, "Q")
      press(pid, "]")

      state = user_state(pid)
      assert Enum.map(state.queue, & &1.title) == ["B", "A", "C"]
      assert Enum.at(state.queue, state.queue_selected).title == "A"
    end

    test "[ moves the selected item up" do
      Enum.each(["A", "B", "C"], fn t ->
        {:ok, _} = Queue.enqueue(%{title: t, url: "u-#{t}", local: false})
      end)

      pid = start_tui()
      press(pid, "Q")
      press(pid, "j")
      press(pid, "[")

      state = user_state(pid)
      assert Enum.map(state.queue, & &1.title) == ["B", "A", "C"]
      assert Enum.at(state.queue, state.queue_selected).title == "B"
    end

    test "d removes the selected item after confirmation and reclamps the cursor" do
      Enum.each(["A", "B"], fn t ->
        {:ok, _} = Queue.enqueue(%{title: t, url: "u-#{t}", local: false})
      end)

      pid = start_tui()
      press(pid, "Q")
      press(pid, "j")

      # "d" stages a confirmation rather than removing outright; the queue stays.
      press(pid, "d")
      staged = user_state(pid)
      assert staged.mode == :confirm
      assert staged.confirm_return == :queue_manage
      assert length(staged.queue) == 2

      press(pid, "y")
      state = user_state(pid)
      assert state.mode == :queue_manage
      assert Enum.map(state.queue, & &1.title) == ["A"]
      assert state.queue_selected == 0
    end

    test "d then a non-y key cancels the removal, leaving the queue intact" do
      Enum.each(["A", "B"], fn t ->
        {:ok, _} = Queue.enqueue(%{title: t, url: "u-#{t}", local: false})
      end)

      pid = start_tui()
      press(pid, "Q")
      press(pid, "d")
      press(pid, "n")

      state = user_state(pid)
      assert state.mode == :queue_manage
      assert length(state.queue) == 2
    end

    test "c clears the queue after confirmation" do
      {:ok, _} = Queue.enqueue(%{title: "A", url: "u-a", local: false})
      pid = start_tui()
      press(pid, "Q")
      press(pid, "c")

      # "c" stages a confirmation rather than clearing outright; the queue is
      # untouched until the user presses "y".
      staged = user_state(pid)
      assert staged.mode == :confirm
      assert length(staged.queue) == 1

      press(pid, "y")

      state = user_state(pid)
      assert state.mode == :queue_manage
      assert state.queue == []
      assert {:info, "Queue cleared"} = state.status
    end

    test "c then a non-y key cancels the clear, leaving the queue intact" do
      {:ok, _} = Queue.enqueue(%{title: "A", url: "u-a", local: false})
      pid = start_tui()
      press(pid, "Q")
      press(pid, "c")
      press(pid, "n")

      state = user_state(pid)
      assert state.mode == :queue_manage
      assert length(state.queue) == 1
      assert {:info, "Canceled"} = state.status
    end

    test "Enter in the modal starts playback from the head with origin :queue" do
      {:ok, _} = Queue.enqueue(%{title: "First", url: "u-1", local: false})
      pid = start_tui()
      press(pid, "Q")
      press(pid, "enter")

      state = user_state(pid)
      assert state.mode == :playing
      assert state.playing.title == "First"
      assert state.playing.origin == :queue

      assert_receive {TestPlayback, play_task}, 1_000
      send(play_task, :close)
    end

    test "Enter in an empty modal reports the queue is empty" do
      pid = start_tui()
      press(pid, "Q")
      press(pid, "enter")

      state = user_state(pid)
      assert state.mode == :queue_manage
      assert {:error, "Queue is empty"} = state.status
    end

    test "a queued item finishing drops it and auto-advances to the next" do
      {:ok, first} = Queue.enqueue(%{title: "First", url: "u-1", local: false})
      {:ok, _second} = Queue.enqueue(%{title: "Second", url: "u-2", local: false})
      pid = start_tui()

      # Enter :playing on the head with origin :queue.
      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | mode: :playing,
                queue: Queue.list_items(),
                playing: %{title: "First", origin: :queue, queue_id: first.id}
            }
        }
      end)

      send(pid, {:play_result, :ok})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      # First was dropped; the player is now on Second, still in :playing.
      assert state.mode == :playing
      assert state.playing.title == "Second"
      assert state.playing.origin == :queue
      assert Enum.map(state.queue, & &1.title) == ["Second"]

      assert_receive {TestPlayback, play_task}, 1_000
      send(play_task, :close)
    end

    test "the last queued item finishing empties the queue and returns to :list" do
      {:ok, only} = Queue.enqueue(%{title: "Only", url: "u-1", local: false})
      pid = start_tui()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | mode: :playing,
                queue: Queue.list_items(),
                playing: %{title: "Only", origin: :queue, queue_id: only.id}
            }
        }
      end)

      send(pid, {:play_result, :ok})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :list
      assert state.queue == []
      assert {:info, "Queue finished"} = state.status
    end

    test "a queued item failing stops the queue and shows the modal" do
      {:ok, bad} = Queue.enqueue(%{title: "Bad", url: "u-1", local: false})
      {:ok, _next} = Queue.enqueue(%{title: "Next", url: "u-2", local: false})
      pid = start_tui()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | mode: :playing,
                queue: Queue.list_items(),
                playing: %{title: "Bad", origin: :queue, queue_id: bad.id}
            }
        }
      end)

      send(pid, {:play_result, {:error, "vlc exited with 1"}})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :queue_manage
      # Stop-and-report: the failed item stays in place, nothing auto-skips.
      assert Enum.map(state.queue, & &1.title) == ["Bad", "Next"]
      assert {:error, "Playback failed: vlc exited with 1"} = state.status
    end

    test "the modal body lists items with a Source column" do
      {:ok, _} = Queue.enqueue(%{title: "Yt Vid", url: "u-1", local: false})
      {:ok, _} = Queue.enqueue(%{title: "Clip", url: "/v/clip.mp4", local: true})

      state = %{
        view: :bookmarks,
        mode: :queue_manage,
        bookmarks: [],
        subscriptions: [],
        playlists: [],
        queue: Queue.list_items(),
        videos: [],
        channel_name: nil,
        selected: 0,
        queue_selected: 0,
        queue_return: :list,
        input: nil,
        status: nil,
        playing: nil
      }

      widgets = TUI.render(state, frame())
      assert Enum.member?(block_titles(widgets), " Queue ")
    end
  end

  describe "footer error rendering" do
    # A yt-dlp/player failure can carry raw multi-line stderr. The footer is a
    # single 3-row strip, so the message is collapsed to its first non-blank line
    # and length-capped rather than wrapping unreadably.
    defp footer_state(status) do
      %{
        view: :bookmarks,
        mode: :list,
        bookmarks: [],
        subscriptions: [],
        playlists: [],
        queue: [],
        videos: [],
        channel_name: nil,
        selected: 0,
        queue_selected: 0,
        queue_return: :list,
        input: nil,
        status: status,
        playing: nil
      }
    end

    test "a multi-line error is collapsed to its first non-blank line" do
      state = footer_state({:error, "\nyt-dlp failed (exit 1)\nERROR: something\nmore detail"})

      text = footer_text(TUI.render(state, frame()))
      assert text == "yt-dlp failed (exit 1)"
      refute text =~ "\n"
    end

    test "a very long error line is truncated with an ellipsis" do
      long = String.duplicate("x", 500)
      state = footer_state({:error, long})

      text = footer_text(TUI.render(state, frame()))
      assert String.length(text) <= 120
      assert String.ends_with?(text, "…")
    end

    test "a short single-line error passes through unchanged" do
      state = footer_state({:error, "Queue is empty"})

      assert footer_text(TUI.render(state, frame())) == "Queue is empty"
    end
  end

  defp frame, do: %ExRatatui.Frame{width: 80, height: 24}

  # The body is the second widget in the render list (header, body, footer).
  defp body_text(widgets) do
    {widget, _rect} = Enum.at(widgets, 1)
    Map.get(widget, :text)
  end

  # The footer is the last widget in the render list (header, body, footer), or
  # (header, body, input, footer) while adding.
  defp footer_text(widgets) do
    {widget, _rect} = List.last(widgets)
    Map.get(widget, :text)
  end

  # Pull the block titles out of a rendered [{widget, rect}] list.
  defp block_titles(widgets) do
    for {widget, _rect} <- widgets,
        block = Map.get(widget, :block),
        is_map(block),
        title = Map.get(block, :title),
        is_binary(title),
        do: title
  end

  # The row cells of every Table widget rendered this frame, flattened across
  # tables so a test can assert a given row (e.g. ["Live Now", "LIVE"]) appears.
  defp table_rows(widgets) do
    for {widget, _rect} <- widgets,
        rows = Map.get(widget, :rows),
        is_list(rows),
        row <- rows,
        do: row
  end

  # Real unique-constraint error changesets: insert a row, then attempt a
  # duplicate so the returned changeset carries the actual :unique constraint
  # error the TUI's add_error/2 maps to a friendly message (rather than a
  # hand-built changeset that might not match what Ecto really produces).
  defp duplicate_bookmark_changeset do
    url = "https://youtu.be/dup"
    Repo.insert!(%Bookmark{url: url, title: "First", channel: "C"})

    {:error, changeset} =
      %Bookmark{}
      |> Bookmark.changeset(%{url: url, title: "Second", channel: "C"})
      |> Repo.insert()

    changeset
  end

  defp duplicate_subscription_changeset do
    url = "https://youtube.com/@dup"
    Repo.insert!(%Playmark.Subscription{url: url, name: "Chan"})

    {:error, changeset} =
      %Playmark.Subscription{}
      |> Playmark.Subscription.changeset(%{url: url, name: "Chan"})
      |> Repo.insert()

    changeset
  end

  describe "history" do
    setup do
      Application.put_env(:playmark, :playback_impl, TestPlayback)
      Application.put_env(:playmark, :test_playback_pid, self())

      on_exit(fn ->
        Application.delete_env(:playmark, :playback_impl)
        Application.delete_env(:playmark, :test_playback_pid)
      end)
    end

    test "playing a bookmark records a history entry" do
      Repo.insert!(%Bookmark{url: "https://youtu.be/a", title: "A", channel: "C"})
      pid = start_tui()

      press(pid, "enter")
      assert user_state(pid).mode == :playing
      assert_receive {TestPlayback, play_task}, 1_000

      assert [entry] = History.list_items()
      assert entry.title == "A"
      assert entry.url == "https://youtu.be/a"
      assert entry.author == "C"

      send(play_task, :close)
    end

    test "H opens the history modal from :list and Esc restores the prior mode" do
      pid = start_tui()
      assert user_state(pid).mode == :list

      press(pid, "H")
      state = user_state(pid)
      assert state.mode == :history
      assert state.history_return == :list

      press(pid, "esc")
      assert user_state(pid).mode == :list
    end

    test "H opens the history modal from :videos" do
      pid = start_tui()

      :sys.replace_state(pid, fn s ->
        %{s | user_state: %{s.user_state | mode: :videos, videos: [%{title: "V", url: "u"}]}}
      end)

      press(pid, "H")
      state = user_state(pid)
      assert state.mode == :history
      assert state.history_return == :videos
    end

    test "H is a no-op over the running player" do
      Repo.insert!(%Bookmark{url: "https://youtu.be/a", title: "A", channel: "C"})
      pid = start_tui()
      press(pid, "enter")
      assert user_state(pid).mode == :playing
      assert_receive {TestPlayback, play_task}, 1_000

      press(pid, "H")
      assert user_state(pid).mode == :playing

      send(play_task, :close)
    end

    test "j/k navigate within the modal, clamped to the history bounds" do
      Enum.each(["A", "B", "C"], fn t -> {:ok, _} = History.record(%{title: t, url: "u-#{t}"}) end)

      pid = start_tui()
      press(pid, "H")
      assert user_state(pid).history_selected == 0

      press(pid, "k")
      assert user_state(pid).history_selected == 0

      press(pid, "j")
      press(pid, "j")
      assert user_state(pid).history_selected == 2

      press(pid, "j")
      assert user_state(pid).history_selected == 2
    end

    test "d removes the selected entry after confirmation" do
      Enum.each(["A", "B"], fn t -> {:ok, _} = History.record(%{title: t, url: "u-#{t}"}) end)
      pid = start_tui()
      press(pid, "H")

      # "d" stages a confirmation rather than removing outright; the history stays.
      press(pid, "d")
      staged = user_state(pid)
      assert staged.mode == :confirm
      assert staged.confirm_return == :history
      assert length(staged.history) == 2

      press(pid, "y")
      state = user_state(pid)
      assert state.mode == :history
      assert length(state.history) == 1
      assert {:info, "Removed from history"} = state.status
    end

    test "d then a non-y key cancels the removal, leaving history intact" do
      Enum.each(["A", "B"], fn t -> {:ok, _} = History.record(%{title: t, url: "u-#{t}"}) end)
      pid = start_tui()
      press(pid, "H")

      press(pid, "d")
      press(pid, "n")

      state = user_state(pid)
      assert state.mode == :history
      assert length(state.history) == 2
    end

    test "c clears the history after confirmation" do
      {:ok, _} = History.record(%{title: "A", url: "u-a"})
      pid = start_tui()
      press(pid, "H")

      # "c" stages a confirmation rather than clearing outright; the history stays.
      press(pid, "c")
      staged = user_state(pid)
      assert staged.mode == :confirm
      assert staged.confirm_return == :history
      assert length(staged.history) == 1

      press(pid, "y")
      state = user_state(pid)
      assert state.mode == :history
      assert state.history == []
      assert History.list_items() == []
    end

    test "c then a non-y key cancels the clear, leaving the history intact" do
      {:ok, _} = History.record(%{title: "A", url: "u-a"})
      pid = start_tui()
      press(pid, "H")

      press(pid, "c")
      press(pid, "n")
      state = user_state(pid)
      assert state.mode == :history
      assert length(state.history) == 1
      assert History.list_items() != []
    end

    test "Enter replays the selected entry via start_play" do
      {:ok, _} = History.record(%{title: "Rewatch", url: "https://youtu.be/x", author: "Chan"})
      pid = start_tui()
      press(pid, "H")

      press(pid, "enter")
      assert user_state(pid).mode == :playing
      assert_receive {TestPlayback, play_task}, 1_000

      send(play_task, :close)
    end
  end

  defp duplicate_playlist_changeset do
    path = "/tmp/playmark-dup-dir"
    Repo.insert!(%Playmark.Playlist{path: path, name: "dir"})

    {:error, changeset} =
      %Playmark.Playlist{}
      |> Playmark.Playlist.changeset(%{path: path, name: "dir"})
      |> Repo.insert()

    changeset
  end
end
