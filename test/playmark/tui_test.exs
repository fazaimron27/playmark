defmodule Playmark.TUITest.TestPlayback do
  @moduledoc """
  A stub player for the TUI's playback seam. `play/3` reports the `:playing`
  stage through the progress reporter (mirroring a real backend), tells the test
  process the task has started (handing it the task pid), then blocks until
  released with `:close`, modelling a real player that stays open until the user
  quits — so a test can observe the non-blocking `:playing` state before playback
  ends. `subtitles?/0` feeds the TUI's step plan.
  """

  def player, do: Application.get_env(:playmark, :test_player, :test)

  def subtitles?, do: false
  def resume_supported?, do: Application.get_env(:playmark, :test_resume_supported, true)

  # The TUI passes a display meta map (%{title, author}) as the middle arg (see
  # start_play); the stub ignores it and behaves like a real backend advancing
  # to :playing.
  def play(_url, _meta, progress, start_position_ms),
    do: announce_and_block(progress, start_position_ms)

  # Local playback goes through play_local/3 instead of play/3; behave the same
  # so a test can observe the non-blocking :playing state for a local file too.
  def play_local(_path, _meta, progress, start_position_ms),
    do: announce_and_block(progress, start_position_ms)

  defp announce_and_block(progress, start_position_ms) do
    progress.(:playing)

    test_pid = Application.get_env(:playmark, :test_playback_pid)
    send(test_pid, {__MODULE__, self()})
    send(test_pid, {__MODULE__, :start_position, start_position_ms})

    await_close(progress, test_pid)
  end

  defp await_close(progress, test_pid) do
    receive do
      :close ->
        {:ok, :completed}

      {:close, result} ->
        result

      {:progress, event} ->
        progress.(event)
        send(test_pid, {__MODULE__, :progress, event})
        await_close(progress, test_pid)
    after
      5_000 -> {:ok, :completed}
    end
  end
end

defmodule Playmark.TUITest.TestLocalFiles do
  @moduledoc """
  A stub for the TUI's local-filesystem seam. `list_entries/1` announces itself to
  the test process (handing it the task pid) and blocks until the test sends the
  entries to return, so a test can observe the non-blocking `:loading` state before
  the list arrives — mirroring `TestChannel`.
  """

  def list_entries(dir, _root) do
    test_pid = Application.get_env(:playmark, :test_local_files_pid)
    send(test_pid, {__MODULE__, self(), dir})

    receive do
      {:result, result} -> result
      {:entries, entries} -> {:ok, entries}
      {:files, files} -> {:ok, files}
    after
      5_000 -> {:ok, []}
    end
  end
end

defmodule Playmark.TUITest.TestYouTubePlaylist do
  @moduledoc false

  def metadata(_url), do: {:ok, %{title: "Stub Playlist", channel: "Stub Channel"}}

  def list_videos(url, _limit \\ 100) do
    test_pid = Application.get_env(:playmark, :test_youtube_playlist_pid)
    send(test_pid, {__MODULE__, self(), url})

    receive do
      {:result, result} -> result
      {:videos, videos} -> {:ok, videos}
    after
      5_000 -> {:ok, []}
    end
  end
end

defmodule Playmark.TUITest.TestPlaylists do
  @moduledoc false

  def save_playlist(playlist, channel) do
    test_pid = Application.get_env(:playmark, :test_playlists_pid)
    send(test_pid, {__MODULE__, self(), playlist, channel})

    receive do
      {:result, result} -> result
    after
      5_000 -> {:error, "timed out"}
    end
  end
end

defmodule Playmark.TUITest.TestChannel do
  @moduledoc """
  A channel seam whose video and playlist listing calls announce themselves to
  the test process and block until the test supplies a result.
  """

  def name(_url), do: {:ok, "Stub Channel"}

  def list_videos(_url, tab \\ :videos) do
    test_pid = Application.get_env(:playmark, :test_channel_pid)
    send(test_pid, {__MODULE__, self(), tab})

    receive do
      {:videos, videos} -> {:ok, videos}
      {:result, result} -> result
    after
      5_000 -> {:ok, []}
    end
  end

  def list_playlists(_url) do
    test_pid = Application.get_env(:playmark, :test_channel_pid)
    send(test_pid, {__MODULE__, self(), :playlists})

    receive do
      {:playlists, playlists} -> {:ok, playlists}
      {:result, result} -> result
    after
      5_000 -> {:ok, []}
    end
  end
end

defmodule Playmark.TUITest.TestSearch do
  @moduledoc """
  A stub for the TUI's search seam. `search/1` announces itself to the test
  process (handing it the task pid) and blocks until the test sends the results
  to return, so a test can observe the non-blocking `:search_loading` state before the
  results arrive — mirroring `TestChannel`.
  """

  def search(query, _limit \\ 20) do
    test_pid = Application.get_env(:playmark, :test_search_pid)
    send(test_pid, {__MODULE__, self(), query})

    receive do
      {:results, videos} -> {:ok, videos}
      {:result, result} -> result
    after
      5_000 -> {:ok, []}
    end
  end
end

defmodule Playmark.TUITest.TestExplore do
  @moduledoc """
  A blocking Explore seam used to observe loading, cancellation, and stale
  homepage results without contacting YouTube.
  """

  def homepage(_limit \\ 20) do
    test_pid = Application.get_env(:playmark, :test_explore_pid)
    send(test_pid, {__MODULE__, self()})

    receive do
      {:result, result} -> result
      {:videos, videos} -> {:ok, videos}
    after
      5_000 -> {:ok, []}
    end
  end
end

defmodule Playmark.TUITest do
  # test_mode disables live terminal polling; still touches the DB, so not async.
  use Playmark.DataCase, async: false

  alias Playmark.TUITest.TestChannel
  alias Playmark.TUITest.TestExplore
  alias Playmark.TUITest.TestLocalFiles
  alias Playmark.TUITest.TestPlayback
  alias Playmark.TUITest.TestPlaylists
  alias Playmark.TUITest.TestSearch
  alias Playmark.TUITest.TestYouTubePlaylist

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

  defp stub_playback do
    Application.put_env(:playmark, :playback_impl, TestPlayback)
    Application.put_env(:playmark, :test_playback_pid, self())

    on_exit(fn ->
      Application.delete_env(:playmark, :playback_impl)
      Application.delete_env(:playmark, :test_playback_pid)
      Application.delete_env(:playmark, :test_resume_supported)
    end)
  end

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

  test "g/G/Home/End jump to first and last, PageUp/PageDown move by step" do
    for i <- 1..25 do
      Repo.insert!(%Bookmark{url: "https://youtu.be/#{i}", title: "V#{i}", channel: "C"})
    end

    pid = start_tui()

    # move to middle
    for _ <- 1..12, do: press(pid, "j")
    assert user_state(pid).selected == 12

    # G jumps to last (index 24)
    press(pid, "G")
    assert user_state(pid).selected == 24

    # g jumps to first
    press(pid, "g")
    assert user_state(pid).selected == 0

    # End jumps to last
    press(pid, "end")
    assert user_state(pid).selected == 24

    # Home jumps to first
    press(pid, "home")
    assert user_state(pid).selected == 0

    # page_down moves by 10
    press(pid, "page_down")
    assert user_state(pid).selected == 10

    # page_up moves back by 10
    press(pid, "page_up")
    assert user_state(pid).selected == 0

    # page_up at top clamps to 0
    press(pid, "page_up")
    assert user_state(pid).selected == 0

    # page_down at bottom clamps to last
    press(pid, "G")
    press(pid, "page_down")
    assert user_state(pid).selected == 24
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

      input_widget = input_widget(TUI.render(user_state(pid), frame()))
      assert :reversed in input_widget.cursor_style.modifiers

      type(pid, "hello")
      assert ExRatatui.text_input_get_value(user_state(pid).input) == "hello"
    end

    test "the block cursor follows movement while correcting text" do
      pid = start_tui()

      press(pid, "a")
      type(pid, "ecample")

      for _ <- 1..6, do: press(pid, "left")
      assert ExRatatui.text_input_cursor(user_state(pid).input) == 1

      press(pid, "delete")
      type(pid, "x")
      assert ExRatatui.text_input_get_value(user_state(pid).input) == "example"
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

    test "non-Esc keys are ignored while fetching" do
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

      send(pid, {:add_result, {:error, duplicate_local_changeset()}, :local})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :input
      assert {:error, "Directory already registered"} = state.status
    end
  end

  describe "playback flow" do
    test "Enter on a bookmark enters :playing mode without blocking" do
      # Stub the player so the suite never spawns a real player or hits the
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

    test "a saved checkpoint prompts before playback and y resumes from it" do
      stub_playback()
      url = "https://youtu.be/resume"
      Repo.insert!(%Bookmark{url: url, title: "Long Video", channel: "C"})
      {:ok, _item} = History.record(%{title: "Long Video", url: url, local: false})
      {:ok, _item} = History.save_checkpoint(url, 125_000, 600_000)
      pid = start_tui()

      press(pid, "enter")

      state = user_state(pid)
      assert state.mode == :resume
      assert state.resume.position_ms == 125_000
      assert footer_text(TUI.render(state, frame())) =~ "Resume \"Long Video\" from 2:05?"
      refute_receive {TestPlayback, _task}, 50

      press(pid, "y")
      assert user_state(pid).mode == :playing
      assert_receive {TestPlayback, play_task}, 1_000
      assert_receive {TestPlayback, :start_position, 125_000}, 1_000
      send(play_task, :close)
    end

    test "n starts over and clears the old checkpoint" do
      stub_playback()
      url = "https://youtu.be/restart"
      Repo.insert!(%Bookmark{url: url, title: "Restart Me", channel: "C"})
      {:ok, _item} = History.record(%{title: "Restart Me", url: url, local: false})
      {:ok, _item} = History.save_checkpoint(url, 90_000, 500_000)
      pid = start_tui()

      press(pid, "enter")
      press(pid, "n")

      assert user_state(pid).mode == :playing
      assert History.get_checkpoint(url) == nil
      assert_receive {TestPlayback, play_task}, 1_000
      assert_receive {TestPlayback, :start_position, nil}, 1_000
      send(play_task, :close)
    end

    test "Esc cancels a resume prompt without launching playback" do
      stub_playback()
      url = "https://youtu.be/cancel-resume"
      Repo.insert!(%Bookmark{url: url, title: "Keep My Place", channel: "C"})
      {:ok, _item} = History.record(%{title: "Keep My Place", url: url, local: false})
      {:ok, _item} = History.save_checkpoint(url, 70_000, 400_000)
      pid = start_tui()

      press(pid, "enter")
      press(pid, "esc")

      assert user_state(pid).mode == :list
      assert user_state(pid).playing == nil
      assert History.get_checkpoint(url).resume_position_ms == 70_000
      refute_receive {TestPlayback, _task}, 50
    end

    test "player checkpoint events persist and completion clears the position" do
      stub_playback()
      url = "https://youtu.be/checkpoint"
      Repo.insert!(%Bookmark{url: url, title: "Checkpoint", channel: "C"})
      pid = start_tui()

      press(pid, "enter")
      assert_receive {TestPlayback, play_task}, 1_000
      assert_receive {TestPlayback, :start_position, nil}, 1_000

      send(play_task, {:progress, {:checkpoint, 45_000, 300_000}})
      assert_receive {TestPlayback, :progress, {:checkpoint, 45_000, 300_000}}, 1_000
      assert History.get_checkpoint(url) == %{resume_position_ms: 45_000, duration_ms: 300_000}

      send(play_task, {:progress, :clear_checkpoint})
      assert_receive {TestPlayback, :progress, :clear_checkpoint}, 1_000
      assert History.get_checkpoint(url) == nil
      send(play_task, :close)
    end

    test "ffplay does not offer resume even when history has a checkpoint" do
      stub_playback()
      Application.put_env(:playmark, :test_resume_supported, false)
      Application.put_env(:playmark, :test_player, :ffplay)

      on_exit(fn -> Application.delete_env(:playmark, :test_player) end)

      url = "https://youtu.be/ffplay-resume"
      Repo.insert!(%Bookmark{url: url, title: "No Resume", channel: "C"})
      {:ok, _item} = History.record(%{title: "No Resume", url: url, local: false})
      {:ok, _item} = History.save_checkpoint(url, 70_000, 400_000)
      pid = start_tui()

      press(pid, "enter")

      assert user_state(pid).mode == :playing
      assert_receive {TestPlayback, play_task}, 1_000
      assert_receive {TestPlayback, :start_position, nil}, 1_000
      send(play_task, :close)
    end

    test "ffplay progress resolves a muxed stream without a caption step" do
      original_subtitles = Application.fetch_env(:playmark, :subtitles)
      Application.put_env(:playmark, :playback_impl, TestPlayback)
      Application.put_env(:playmark, :test_playback_pid, self())
      Application.put_env(:playmark, :test_player, :ffplay)
      Application.put_env(:playmark, :subtitles, true)

      on_exit(fn ->
        Application.delete_env(:playmark, :playback_impl)
        Application.delete_env(:playmark, :test_playback_pid)
        Application.delete_env(:playmark, :test_player)

        case original_subtitles do
          {:ok, value} -> Application.put_env(:playmark, :subtitles, value)
          :error -> Application.delete_env(:playmark, :subtitles)
        end
      end)

      Repo.insert!(%Bookmark{url: "https://youtu.be/play", title: "V", channel: "C"})
      pid = start_tui()
      press(pid, "enter")

      playing = user_state(pid).playing
      assert playing.player == :ffplay
      assert playing.steps == [:resolving, :playing]
      assert playing.stream == %{max_height: Playmark.Player.Playback.max_height(), result: nil}
      assert playing.captions == nil

      assert_receive {TestPlayback, play_task}, 1_000
      send(play_task, :close)
    end

    test "Enter with no bookmarks stays in list mode" do
      pid = start_tui()
      press(pid, "enter")
      assert user_state(pid).mode == :list
    end

    test "non-Q keys are ignored while playing" do
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
      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{s | user_state: %{s.user_state | mode: :playing, playing: %{ref: ref}}}
      end)

      send(pid, {:play_result, ref, {:ok, :completed}})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :list
      assert state.status == nil
    end

    test "a failed play result returns to list mode with an error" do
      pid = start_tui()
      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{s | user_state: %{s.user_state | mode: :playing, playing: %{ref: ref}}}
      end)

      send(pid, {:play_result, ref, {:error, "vlc exited with 1"}})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :list
      assert {:error, "Playback failed: vlc exited with 1"} = state.status
    end

    test "a stale playback result cannot close the active player" do
      pid = start_tui()
      active_ref = make_ref()

      :sys.replace_state(pid, fn s ->
        playing = %{ref: active_ref, title: "Current", return_mode: :list}
        %{s | user_state: %{s.user_state | mode: :playing, playing: playing}}
      end)

      send(pid, {:play_result, make_ref(), {:ok, :completed}})
      _ = :sys.get_state(pid)

      assert user_state(pid).mode == :playing
      assert user_state(pid).playing.ref == active_ref
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

    test "Tab cycles bookmarks -> subscriptions -> playlists -> locals -> bookmarks" do
      pid = start_tui()
      assert user_state(pid).view == :bookmarks

      press(pid, "tab")
      assert user_state(pid).view == :subscriptions

      press(pid, "tab")
      assert user_state(pid).view == :playlists

      press(pid, "tab")
      assert user_state(pid).view == :locals

      press(pid, "tab")
      assert user_state(pid).view == :bookmarks
    end

    test "empty Subscriptions points Tab to Playlists" do
      pid = start_tui()
      press(pid, "tab")

      widgets = TUI.render(user_state(pid), frame())

      assert body_text(widgets) =~ "Tab for Playlists"
      refute body_text(widgets) =~ "Tab for Bookmarks"
    end

    test "every base view shows the same global controls on a visible footer row" do
      pid = start_tui()

      for {view, next_view} <- [
            bookmarks: "Subscriptions",
            subscriptions: "Playlists",
            playlists: "Locals",
            locals: "Bookmarks"
          ] do
        state = user_state(pid)
        assert state.view == view

        widgets = TUI.render(state, frame())
        {_, footer_area} = List.last(widgets)
        footer = footer_text(widgets)

        assert footer_area.height == 4
        assert footer =~ "\nS: search | E: explore | Q: queue | H: history"
        assert footer =~ "Tab: #{next_view}"
        assert footer =~ "q: quit"

        press(pid, "tab")
      end
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
      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{s | user_state: %{s.user_state | mode: :loading, channel_request_ref: ref}}
      end)

      videos = [%{id: "x", title: "Vid X", url: "https://youtu.be/x"}]

      send(
        pid,
        {:videos_result, ref, {:ok, videos}, "Channel A", "https://youtube.com/@a", :videos}
      )

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
      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{s | user_state: %{s.user_state | mode: :loading, channel_request_ref: ref}}
      end)

      send(
        pid,
        {:videos_result, ref, {:error, "yt-dlp failed"}, "Channel A", "https://youtube.com/@a",
         :videos}
      )

      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :list
      assert {:error, _} = state.status
    end

    test "opening a channel without a Videos tab falls back to Streams" do
      insert_sub("https://youtube.com/@streams-only", "Streams Only")
      pid = start_tui()

      press(pid, "tab")
      press(pid, "enter")

      assert_receive {TestChannel, videos_task, :videos}, 1_000

      send(
        videos_task,
        {:result,
         {:error,
          "yt-dlp failed (exit 1): ERROR: [youtube:tab] @streams-only: This channel does not have a videos tab"}}
      )

      assert_receive {TestChannel, streams_task, :streams}, 1_000

      streams = [%{id: "s1", title: "Live Now", url: "u1", live: :live}]
      send(streams_task, {:videos, streams})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :videos
      assert state.video_tab == :streams
      assert state.videos == streams
      assert state.status == {:info, "1 stream from Streams Only"}
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
        {:videos_result, make_ref(), {:ok, [%{id: "x", title: "X", url: "u"}]}, "A",
         "https://youtube.com/@a", :videos}
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

    test "an explicit switch to a missing Videos tab does not fall back" do
      pid = start_tui()
      streams = [%{id: "s1", title: "Live", url: "u", live: :live}]

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | view: :subscriptions,
                mode: :videos,
                videos: streams,
                channel_name: "Streams Only",
                channel_url: "https://youtube.com/@streams-only",
                video_tab: :streams
            }
        }
      end)

      press(pid, "v")
      assert_receive {TestChannel, videos_task, :videos}, 1_000

      send(
        videos_task,
        {:result, {:error, "This channel does not have a videos tab"}}
      )

      _ = :sys.get_state(pid)
      state = user_state(pid)
      assert state.mode == :videos
      assert state.video_tab == :streams
      assert state.videos == streams
      assert {:error, "Could not load videos: " <> _} = state.status
      refute_receive {TestChannel, _task, :streams}, 200
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
      ref = make_ref()

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
                channel_request_ref: ref,
                video_tab: :videos
            }
        }
      end)

      send(
        pid,
        {:videos_result, ref, {:error, "yt-dlp failed"}, "Channel A", "https://youtube.com/@a",
         :streams}
      )

      _ = :sys.get_state(pid)

      state = user_state(pid)
      # Error surfaced, but the previously-shown list stays on screen.
      assert state.mode == :videos
      assert state.videos == videos
      assert {:error, _} = state.status
    end

    test "p lists channel playlist containers before any playlist videos" do
      pid = start_tui()

      :sys.replace_state(pid, fn runtime ->
        %{
          runtime
          | user_state: %{
              runtime.user_state
              | view: :subscriptions,
                mode: :videos,
                videos: [%{id: "x", title: "Upload", url: "u", live: :none}],
                channel_name: "Channel A",
                channel_url: "https://youtube.com/@a",
                video_tab: :videos
            }
        }
      end)

      press(pid, "p")
      assert user_state(pid).mode == :channel_playlists_loading
      assert_receive {TestChannel, task, :playlists}, 1_000

      playlists = [
        %{
          id: "PL123",
          title: "Course",
          url: "https://www.youtube.com/playlist?list=PL123"
        }
      ]

      send(task, {:playlists, playlists})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :channel_playlists
      assert state.channel_playlists == playlists
      assert state.videos == [%{id: "x", title: "Upload", url: "u", live: :none}]

      widgets = TUI.render(%{state | status: nil}, frame())
      assert Enum.member?(block_titles(widgets), " Playlists ")
      assert Enum.member?(table_rows(widgets), ["Course"])
      assert footer_text(widgets) =~ "p: save"
    end

    test "Enter on a channel playlist opens its videos and Esc returns to the containers" do
      Application.put_env(:playmark, :youtube_playlist_impl, TestYouTubePlaylist)
      Application.put_env(:playmark, :test_youtube_playlist_pid, self())

      on_exit(fn ->
        Application.delete_env(:playmark, :youtube_playlist_impl)
        Application.delete_env(:playmark, :test_youtube_playlist_pid)
      end)

      playlist = %{
        id: "PL123",
        title: "Course",
        url: "https://www.youtube.com/playlist?list=PL123"
      }

      pid = start_tui()

      :sys.replace_state(pid, fn runtime ->
        %{
          runtime
          | user_state: %{
              runtime.user_state
              | view: :subscriptions,
                mode: :channel_playlists,
                channel_playlists: [playlist],
                channel_playlist_channel_name: "Channel A",
                channel_playlist_channel_url: "https://youtube.com/@a"
            }
        }
      end)

      press(pid, "enter")
      assert user_state(pid).mode == :loading
      assert_receive {TestYouTubePlaylist, task, url}, 1_000
      assert url == playlist.url

      videos = [
        %{
          id: "abcdefghijk",
          title: "Episode",
          url: "https://www.youtube.com/watch?v=abcdefghijk",
          author: "Channel A",
          live: :none
        }
      ]

      send(task, {:videos, videos})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :videos
      assert state.videos == videos
      assert state.videos_return == :channel_playlists
      assert state.channel_url == nil

      press(pid, "esc")
      state = user_state(pid)
      assert state.mode == :channel_playlists
      assert state.channel_playlists == [playlist]
      assert state.channel_name == "Channel A"
      assert state.channel_url == "https://youtube.com/@a"
    end

    test "p on a channel playlist saves it without leaving the container list" do
      Application.put_env(:playmark, :playlists_impl, TestPlaylists)
      Application.put_env(:playmark, :test_playlists_pid, self())

      on_exit(fn ->
        Application.delete_env(:playmark, :playlists_impl)
        Application.delete_env(:playmark, :test_playlists_pid)
      end)

      playlist = %{
        id: "PL123",
        title: "Course",
        url: "https://www.youtube.com/playlist?list=PL123"
      }

      pid = start_tui()

      :sys.replace_state(pid, fn runtime ->
        %{
          runtime
          | user_state: %{
              runtime.user_state
              | view: :subscriptions,
                mode: :channel_playlists,
                channel_playlists: [playlist],
                channel_playlist_channel_name: "Channel A",
                channel_playlist_channel_url: "https://youtube.com/@a"
            }
        }
      end)

      press(pid, "p")
      assert_receive {TestPlaylists, task, ^playlist, "Channel A"}, 1_000

      press(pid, "p")
      refute_receive {TestPlaylists, _second_task, ^playlist, "Channel A"}, 100

      saved =
        Repo.insert!(%Playmark.Playlist{
          url: playlist.url,
          title: playlist.title,
          channel: "Channel A"
        })

      send(task, {:result, {:ok, saved}})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :channel_playlists
      assert state.playlists == [saved]
      assert {:info, "Saved playlist: Course"} = state.status
    end

    test "channel playlist filtering controls which container Enter opens" do
      Application.put_env(:playmark, :youtube_playlist_impl, TestYouTubePlaylist)
      Application.put_env(:playmark, :test_youtube_playlist_pid, self())

      on_exit(fn ->
        Application.delete_env(:playmark, :youtube_playlist_impl)
        Application.delete_env(:playmark, :test_youtube_playlist_pid)
      end)

      playlists = [
        %{id: "PL1", title: "Music", url: "https://youtube.com/playlist?list=PL1"},
        %{id: "PL2", title: "Elixir Course", url: "https://youtube.com/playlist?list=PL2"}
      ]

      pid = start_tui()

      :sys.replace_state(pid, fn runtime ->
        %{
          runtime
          | user_state: %{
              runtime.user_state
              | view: :subscriptions,
                mode: :channel_playlists,
                channel_playlists: playlists,
                channel_playlist_channel_name: "Channel A",
                channel_playlist_channel_url: "https://youtube.com/@a",
                status: nil
            }
        }
      end)

      press(pid, "/")
      type(pid, "elixr")
      press(pid, "left")
      type(pid, "i")

      input_widget = input_widget(TUI.render(user_state(pid), frame()))
      assert :reversed in input_widget.cursor_style.modifiers

      press(pid, "enter")
      assert user_state(pid).channel_playlist_filter == "elixir"

      press(pid, "/")
      assert ExRatatui.text_input_get_value(user_state(pid).input) == "elixir"
      assert ExRatatui.text_input_cursor(user_state(pid).input) == 6
      press(pid, "enter")

      press(pid, "enter")
      assert_receive {TestYouTubePlaylist, task, url}, 1_000
      assert url == "https://youtube.com/playlist?list=PL2"
      send(task, {:videos, []})
    end

    test "v and s switch from playlist containers to playable channel tabs" do
      pid = start_tui()

      :sys.replace_state(pid, fn runtime ->
        %{
          runtime
          | user_state: %{
              runtime.user_state
              | view: :subscriptions,
                mode: :channel_playlists,
                channel_playlists: [],
                channel_playlist_channel_name: "Channel A",
                channel_playlist_channel_url: "https://youtube.com/@a"
            }
        }
      end)

      press(pid, "s")
      assert_receive {TestChannel, task, :streams}, 1_000
      send(task, {:videos, [%{id: "s", title: "Live", url: "u", live: :live}]})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :videos
      assert state.video_tab == :streams
      assert state.videos_return == :list
    end

    test "canceling a channel playlist fetch kills it and restores the video tab" do
      pid = start_tui()

      :sys.replace_state(pid, fn runtime ->
        %{
          runtime
          | user_state: %{
              runtime.user_state
              | view: :subscriptions,
                mode: :videos,
                videos: [%{id: "x", title: "Upload", url: "u", live: :none}],
                channel_name: "Channel A",
                channel_url: "https://youtube.com/@a"
            }
        }
      end)

      press(pid, "p")
      assert_receive {TestChannel, task, :playlists}, 1_000
      press(pid, "esc")

      state = user_state(pid)
      assert state.mode == :videos
      refute Process.alive?(task)
      assert state.channel_playlists_request_ref == nil
    end

    test "a canceled channel-tab result cannot replace a newer tab request" do
      pid = start_tui()

      :sys.replace_state(pid, fn runtime ->
        %{
          runtime
          | user_state: %{
              runtime.user_state
              | view: :subscriptions,
                mode: :videos,
                videos: [%{id: "x", title: "Upload", url: "u", live: :none}],
                channel_name: "Channel A",
                channel_url: "https://youtube.com/@a",
                video_tab: :videos
            }
        }
      end)

      press(pid, "s")
      assert_receive {TestChannel, old_task, :streams}, 1_000
      old_ref = user_state(pid).channel_request_ref
      press(pid, "esc")
      refute Process.alive?(old_task)

      press(pid, "s")
      assert_receive {TestChannel, new_task, :streams}, 1_000
      new_ref = user_state(pid).channel_request_ref
      refute old_ref == new_ref

      send(
        pid,
        {:videos_result, old_ref, {:ok, [%{title: "Stale", url: "stale"}]}, "Channel A",
         "https://youtube.com/@a", :streams}
      )

      _ = :sys.get_state(pid)
      assert user_state(pid).mode == :loading
      assert user_state(pid).channel_request_ref == new_ref

      send(new_task, {:videos, [%{id: "s", title: "Current", url: "u", live: :live}]})
    end

    test "a canceled playlist-video result cannot replace a channel-tab request" do
      Application.put_env(:playmark, :youtube_playlist_impl, TestYouTubePlaylist)
      Application.put_env(:playmark, :test_youtube_playlist_pid, self())

      on_exit(fn ->
        Application.delete_env(:playmark, :youtube_playlist_impl)
        Application.delete_env(:playmark, :test_youtube_playlist_pid)
      end)

      playlist = %{
        id: "PL123",
        title: "Course",
        url: "https://www.youtube.com/playlist?list=PL123"
      }

      pid = start_tui()

      :sys.replace_state(pid, fn runtime ->
        %{
          runtime
          | user_state: %{
              runtime.user_state
              | view: :subscriptions,
                mode: :channel_playlists,
                channel_playlists: [playlist],
                channel_playlist_channel_name: "Channel A",
                channel_playlist_channel_url: "https://youtube.com/@a"
            }
        }
      end)

      press(pid, "enter")
      assert_receive {TestYouTubePlaylist, old_task, _url}, 1_000
      old_ref = user_state(pid).playlist_request_ref
      press(pid, "esc")
      refute Process.alive?(old_task)

      press(pid, "s")
      assert_receive {TestChannel, channel_task, :streams}, 1_000
      channel_ref = user_state(pid).channel_request_ref

      send(
        pid,
        {:playlist_videos_result, old_ref, {:ok, [%{title: "Stale", url: "u"}]}, "Course"}
      )

      _ = :sys.get_state(pid)
      assert user_state(pid).mode == :loading
      assert user_state(pid).channel_request_ref == channel_ref

      send(channel_task, {:videos, [%{id: "s", title: "Current", url: "u", live: :live}]})
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

  describe "Search overlay" do
    setup do
      Application.put_env(:playmark, :search_impl, TestSearch)
      Application.put_env(:playmark, :test_search_pid, self())

      on_exit(fn ->
        Application.delete_env(:playmark, :search_impl)
        Application.delete_env(:playmark, :test_search_pid)
        Application.delete_env(:playmark, :playback_impl)
        Application.delete_env(:playmark, :test_playback_pid)
      end)
    end

    defp submit_search(pid, query) do
      press(pid, "S")
      type(pid, query)
      press(pid, "enter")
      assert_receive {TestSearch, task, ^query}, 1_000
      task
    end

    test "S opens Search over a list and Esc restores it" do
      pid = start_tui()
      assert user_state(pid).view == :bookmarks

      press(pid, "S")
      state = user_state(pid)
      assert state.mode == :search_input
      assert state.search_return == :list
      assert state.view == :bookmarks

      input_widget = input_widget(TUI.render(state, frame()))
      assert :reversed in input_widget.cursor_style.modifiers

      :ok = Runtime.inject_event(pid, %Event.Paste{content: "today's news"})
      assert ExRatatui.text_input_get_value(user_state(pid).input) == "today's news"

      press(pid, "esc")
      assert user_state(pid).mode == :list
      assert user_state(pid).view == :bookmarks
    end

    test "S preserves an underlying video list and its filter" do
      pid = start_tui()
      videos = [%{title: "Underlying", url: "u"}]

      :sys.replace_state(pid, fn runtime ->
        %{
          runtime
          | user_state: %{
              runtime.user_state
              | view: :subscriptions,
                mode: :videos,
                videos: videos,
                selected: 0,
                filter: "under"
            }
        }
      end)

      press(pid, "S")
      press(pid, "esc")

      state = user_state(pid)
      assert state.mode == :videos
      assert state.videos == videos
      assert state.filter == "under"
      assert state.selected == 0
    end

    test "an empty query stays in Search input with a specific error" do
      pid = start_tui()
      press(pid, "S")
      press(pid, "enter")

      assert user_state(pid).mode == :search_input
      assert {:error, "Enter a query first"} = user_state(pid).status
    end

    test "submitting a query is non-blocking and populates isolated results" do
      pid = start_tui()
      task = submit_search(pid, "today's news")

      state = user_state(pid)
      assert state.mode == :search_loading
      assert is_reference(state.search_request_ref)
      assert state.search_task_pid == task

      videos = [%{id: "x", title: "Vid X", url: "https://youtu.be/x", author: "Chan"}]
      send(task, {:results, videos})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :search_results
      assert state.search_videos == videos
      assert state.search_query == "today's news"
      assert state.search_request_ref == nil
      assert state.search_task_pid == nil
      assert state.videos == []
      assert {:info, "1 result for today's news"} = state.status
    end

    test "empty results stay in the overlay and failures keep the query editable" do
      pid = start_tui()
      empty_task = submit_search(pid, "obscure")
      send(empty_task, {:results, []})
      _ = :sys.get_state(pid)

      assert user_state(pid).mode == :search_results
      assert {:info, "No results for obscure"} = user_state(pid).status

      press(pid, "S")
      type(pid, "retry")
      press(pid, "enter")
      assert_receive {TestSearch, failed_task, "retry"}, 1_000
      send(failed_task, {:result, {:error, "yt-dlp failed"}})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :search_input
      assert {:error, "Search failed: yt-dlp failed"} = state.status
      assert ExRatatui.text_input_get_value(state.input) == "retry"
    end

    test "Esc cancels loading, kills the task, and restores the origin" do
      pid = start_tui()
      task = submit_search(pid, "slow")

      press(pid, "esc")

      state = user_state(pid)
      assert state.mode == :list
      assert state.search_request_ref == nil
      assert state.search_task_pid == nil
      refute Process.alive?(task)
    end

    test "a stale request cannot replace a newer search" do
      pid = start_tui()
      old_task = submit_search(pid, "old")
      old_ref = user_state(pid).search_request_ref
      press(pid, "esc")
      refute Process.alive?(old_task)

      new_task = submit_search(pid, "new")
      new_ref = user_state(pid).search_request_ref
      refute new_ref == old_ref

      send(pid, {:search_result, old_ref, {:ok, [%{title: "Old", url: "u"}]}, "old"})
      _ = :sys.get_state(pid)
      assert user_state(pid).mode == :search_loading
      assert user_state(pid).search_request_ref == new_ref

      send(new_task, {:results, [%{title: "New", url: "u2"}]})
      _ = :sys.get_state(pid)
      assert [%{title: "New"}] = user_state(pid).search_videos
    end

    test "results have independent navigation and filtering" do
      pid = start_tui()

      :sys.replace_state(pid, fn runtime ->
        %{
          runtime
          | user_state: %{
              runtime.user_state
              | mode: :search_results,
                search_videos: [
                  %{title: "Cats", url: "u1"},
                  %{title: "Dogs", url: "u2"},
                  %{title: "Cat food", url: "u3"}
                ],
                search_query: "pets"
            }
        }
      end)

      press(pid, "j")
      assert user_state(pid).search_selected == 1
      press(pid, "/")
      type(pid, "ct")
      press(pid, "left")
      type(pid, "a")

      input_widget = input_widget(TUI.render(user_state(pid), frame()))
      assert :reversed in input_widget.cursor_style.modifiers

      press(pid, "enter")

      state = user_state(pid)
      assert state.mode == :search_results
      assert state.search_filter == "cat"
      assert state.search_selected == 0

      press(pid, "/")
      assert ExRatatui.text_input_get_value(user_state(pid).input) == "cat"
      assert ExRatatui.text_input_cursor(user_state(pid).input) == 3
      press(pid, "enter")

      press(pid, "esc")
      assert user_state(pid).search_filter == ""
      assert user_state(pid).mode == :search_results
    end

    test "Search over Locals queues and plays results as YouTube" do
      Application.put_env(:playmark, :playback_impl, TestPlayback)
      Application.put_env(:playmark, :test_playback_pid, self())
      pid = start_tui()

      video = %{title: "Online", url: "https://youtu.be/abcdefghijk", author: "Channel"}

      :sys.replace_state(pid, fn runtime ->
        %{
          runtime
          | user_state: %{
              runtime.user_state
              | view: :locals,
                mode: :search_results,
                search_return: :list,
                search_videos: [video]
            }
        }
      end)

      press(pid, "e")
      assert [queued] = user_state(pid).queue
      assert queued.local == false

      press(pid, "enter")
      assert user_state(pid).mode == :playing
      assert user_state(pid).playing.return_mode == :search_results
      assert [entry] = History.list_items()
      assert entry.local == false

      assert_receive {TestPlayback, play_task}, 1_000
      send(play_task, :close)
      _ = :sys.get_state(pid)
      assert user_state(pid).mode == :search_results
    end

    test "Queue and History overlays return to Search results" do
      pid = start_tui()

      :sys.replace_state(pid, fn runtime ->
        %{runtime | user_state: %{runtime.user_state | mode: :search_results}}
      end)

      press(pid, "Q")
      assert user_state(pid).queue_return == :search_results
      press(pid, "esc")
      assert user_state(pid).mode == :search_results

      press(pid, "H")
      assert user_state(pid).history_return == :search_results
      press(pid, "esc")
      assert user_state(pid).mode == :search_results
    end

    test "Queue playback and History replay return to Search results" do
      Application.put_env(:playmark, :playback_impl, TestPlayback)
      Application.put_env(:playmark, :test_playback_pid, self())
      {:ok, _} = Queue.enqueue(%{title: "Queued", url: "https://youtu.be/abcdefghijk"})
      pid = start_tui()

      :sys.replace_state(pid, fn runtime ->
        %{runtime | user_state: %{runtime.user_state | mode: :search_results}}
      end)

      press(pid, "Q")
      press(pid, "enter")
      assert user_state(pid).playing.return_mode == :search_results
      assert_receive {TestPlayback, queue_task}, 1_000
      send(queue_task, :close)
      _ = :sys.get_state(pid)
      assert user_state(pid).mode == :search_results

      press(pid, "H")
      press(pid, "enter")
      assert user_state(pid).playing.return_mode == :search_results
      assert_receive {TestPlayback, history_task}, 1_000
      send(history_task, :close)
    end

    test "Search and Explore remain sibling overlays" do
      pid = start_tui()

      :sys.replace_state(pid, fn runtime ->
        %{runtime | user_state: %{runtime.user_state | mode: :explore}}
      end)

      press(pid, "S")
      assert user_state(pid).mode == :explore

      :sys.replace_state(pid, fn runtime ->
        %{runtime | user_state: %{runtime.user_state | mode: :search_results}}
      end)

      press(pid, "E")
      assert user_state(pid).mode == :search_results
    end

    test "S from results starts a new query without changing the original return" do
      pid = start_tui()

      :sys.replace_state(pid, fn runtime ->
        %{
          runtime
          | user_state: %{runtime.user_state | mode: :search_results, search_return: :videos}
        }
      end)

      press(pid, "S")
      state = user_state(pid)
      assert state.mode == :search_input
      assert state.search_return == :videos
      assert state.search_videos == []
    end

    test "renders Search results and controls independently of the base view" do
      state = %{
        view: :locals,
        mode: :search_results,
        search_videos: [%{id: "x", title: "Vid X", url: "u"}],
        search_selected: 0,
        search_query: "gustixa",
        search_filter: "",
        status: nil
      }

      widgets = TUI.render(state, %ExRatatui.Frame{width: 80, height: 24})

      assert Enum.any?(block_titles(widgets), &String.starts_with?(&1, " Search results"))
      assert footer_text(widgets) =~ "S: new"

      filtered = %{state | search_filter: "vid"}
      filtered_footer = footer_text(TUI.render(filtered, frame()))
      assert filtered_footer =~ "Esc: clear"
      refute filtered_footer =~ "Esc: back"
    end
  end

  describe "video list rendering" do
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

    test "the videos tab renders Title / Duration / Views columns (no Status badges)" do
      state = %{
        view: :subscriptions,
        mode: :videos,
        bookmarks: [],
        subscriptions: [],
        videos: [
          %{
            id: "a",
            title: "Some Video",
            url: "u1",
            live: :none,
            duration: 563,
            views: 4_000_000
          },
          %{id: "b", title: "No Meta", url: "u2", live: :none}
        ],
        channel_name: "Channel A",
        channel_url: "https://youtube.com/@a",
        video_tab: :videos,
        selected: 0,
        input: nil,
        status: nil
      }

      widgets = TUI.render(state, %ExRatatui.Frame{width: 80, height: 24})
      assert Enum.member?(block_titles(widgets), " Videos ")
      rows = table_rows(widgets)
      # Duration renders as M:SS, views as a compact count; a row missing both
      # fields shows blank cells rather than crashing.
      assert Enum.member?(rows, ["Some Video", "9:23", "4M"])
      assert Enum.member?(rows, ["No Meta", "", ""])
    end
  end

  describe "locals view" do
    setup do
      Application.put_env(:playmark, :local_files_impl, TestLocalFiles)
      Application.put_env(:playmark, :test_local_files_pid, self())

      on_exit(fn ->
        Application.delete_env(:playmark, :local_files_impl)
        Application.delete_env(:playmark, :test_local_files_pid)
      end)
    end

    defp to_locals(pid) do
      # bookmarks -> subscriptions -> playlists -> locals
      press(pid, "tab")
      press(pid, "tab")
      press(pid, "tab")
      assert user_state(pid).view == :locals
    end

    defp insert_local(path, name) do
      Repo.insert!(%Playmark.Local{path: path, name: name})
    end

    test "\"a\" opens the register prompt with a path placeholder" do
      pid = start_tui()
      to_locals(pid)

      press(pid, "a")
      assert user_state(pid).mode == :input
    end

    test "an empty Locals input asks for a directory path" do
      pid = start_tui()
      to_locals(pid)

      press(pid, "a")
      press(pid, "enter")

      assert {:error, "Enter a directory path first"} = user_state(pid).status
    end

    test "Enter on a local starts a tracked directory read without blocking" do
      insert_local("/tmp/videos", "videos")
      pid = start_tui()
      to_locals(pid)

      press(pid, "enter")

      state = user_state(pid)
      assert state.mode == :loading
      assert is_reference(state.local_request_ref)
      assert is_pid(state.local_task_pid)
      assert {:info, _} = state.status

      # The task called the stub, which announced itself and blocks.
      assert_receive {TestLocalFiles, task, "/tmp/videos"}, 1_000

      send(task, {
        :entries,
        [%{kind: :file, id: "/tmp/videos/a.mp4", title: "a.mp4", url: "/tmp/videos/a.mp4"}]
      })
    end

    test "a successful root read populates the browser and its root state" do
      insert_local("/tmp/videos", "videos")
      pid = start_tui()
      to_locals(pid)
      press(pid, "enter")
      assert_receive {TestLocalFiles, task, "/tmp/videos"}, 1_000

      entries = [
        %{
          kind: :directory,
          id: "/tmp/videos/season",
          title: "season",
          path: "/tmp/videos/season"
        },
        %{kind: :file, id: "/tmp/videos/a.mp4", title: "a.mp4", url: "/tmp/videos/a.mp4"}
      ]

      send(task, {:entries, entries})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :videos
      assert state.videos == entries
      assert state.channel_name == "videos"
      assert state.local_root == "/tmp/videos"
      assert state.local_path == "/tmp/videos"
      assert state.local_stack == []
      assert state.local_request_ref == nil
      assert {:info, "1 folder, 1 file in videos"} = state.status
    end

    test "an empty directory reports no browsable entries but still opens" do
      insert_local("/tmp/empty", "empty")
      pid = start_tui()
      to_locals(pid)
      press(pid, "enter")
      assert_receive {TestLocalFiles, task, "/tmp/empty"}, 1_000

      send(task, {:entries, []})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :videos
      assert {:info, "No media files or folders in empty"} = state.status
    end

    test "an unavailable registered root returns to Locals without removing it" do
      local = insert_local("/tmp/x", "x")
      pid = start_tui()
      to_locals(pid)
      press(pid, "enter")
      assert_receive {TestLocalFiles, task, "/tmp/x"}, 1_000

      send(task, {:result, {:error, "could not read /tmp/x"}})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :list

      assert {:error, ~s(Local directory "x" is offline or unavailable: could not read /tmp/x)} =
               state.status

      assert Enum.map(Playmark.Locals.list_locals(), & &1.id) == [local.id]
    end

    test "Esc cancels a directory task and rejects its stale result" do
      insert_local("/tmp/videos", "videos")
      pid = start_tui()
      to_locals(pid)
      press(pid, "enter")
      assert_receive {TestLocalFiles, first_task, "/tmp/videos"}, 1_000
      first_ref = user_state(pid).local_request_ref

      press(pid, "esc")
      state = user_state(pid)
      assert state.mode == :list
      assert state.local_request_ref == nil
      refute Process.alive?(first_task)

      press(pid, "enter")
      assert_receive {TestLocalFiles, second_task, "/tmp/videos"}, 1_000
      second_ref = user_state(pid).local_request_ref
      refute second_ref == first_ref

      stale = [%{kind: :file, id: "old", title: "old.mp4", url: "old"}]
      send(pid, {:local_entries_result, first_ref, {:ok, stale}})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :loading
      assert state.local_request_ref == second_ref
      assert state.videos == []

      send(second_task, {:entries, []})
    end

    test "Enter opens folders and Esc restores the exact parent frame" do
      insert_local("/tmp/library", "library")
      pid = start_tui()
      to_locals(pid)
      press(pid, "enter")
      assert_receive {TestLocalFiles, root_task, "/tmp/library"}, 1_000

      root_entries = [
        %{
          kind: :directory,
          id: "/tmp/library/season1",
          title: "season1",
          path: "/tmp/library/season1"
        },
        %{
          kind: :file,
          id: "/tmp/library/movie.mp4",
          title: "movie.mp4",
          url: "/tmp/library/movie.mp4"
        }
      ]

      send(root_task, {:entries, root_entries})
      _ = :sys.get_state(pid)

      :sys.replace_state(pid, fn s ->
        %{s | user_state: %{s.user_state | filter: "season", selected: 0}}
      end)

      press(pid, "enter")
      assert_receive {TestLocalFiles, child_task, "/tmp/library/season1"}, 1_000

      disc = %{
        kind: :directory,
        id: "/tmp/library/season1/disc1",
        title: "disc1",
        path: "/tmp/library/season1/disc1"
      }

      child_file = %{
        kind: :file,
        id: "/tmp/library/season1/ep1.mp4",
        title: "ep1.mp4",
        url: "/tmp/library/season1/ep1.mp4"
      }

      send(child_task, {:entries, [disc, child_file]})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.local_path == "/tmp/library/season1"
      assert state.videos == [disc, child_file]
      assert length(state.local_stack) == 1

      :sys.replace_state(pid, fn s ->
        %{s | user_state: %{s.user_state | filter: "disc", selected: 0}}
      end)

      press(pid, "enter")
      assert_receive {TestLocalFiles, grandchild_task, "/tmp/library/season1/disc1"}, 1_000

      deep_file = %{
        kind: :file,
        id: "/tmp/library/season1/disc1/deep.mp4",
        title: "deep.mp4",
        url: "/tmp/library/season1/disc1/deep.mp4"
      }

      send(grandchild_task, {:entries, [deep_file]})
      _ = :sys.get_state(pid)

      assert user_state(pid).local_path == "/tmp/library/season1/disc1"
      assert length(user_state(pid).local_stack) == 2

      press(pid, "esc")
      state = user_state(pid)
      assert state.local_path == "/tmp/library/season1"
      assert state.videos == [disc, child_file]
      assert state.filter == "disc"

      press(pid, "esc")
      assert user_state(pid).mode == :videos
      assert user_state(pid).filter == ""

      press(pid, "esc")
      state = user_state(pid)
      assert state.local_path == "/tmp/library"
      assert state.videos == root_entries
      assert state.filter == "season"
      assert state.selected == 0

      press(pid, "esc")
      assert user_state(pid).mode == :videos
      assert user_state(pid).filter == ""

      press(pid, "esc")
      assert user_state(pid).mode == :list
      assert user_state(pid).local_path == nil
    end

    test "a child read error leaves the current directory intact" do
      pid = start_tui()

      directory = %{
        kind: :directory,
        id: "/tmp/library/gone",
        title: "gone",
        path: "/tmp/library/gone"
      }

      :sys.replace_state(pid, fn s ->
        user_state = %{
          s.user_state
          | view: :locals,
            mode: :videos,
            videos: [directory],
            channel_name: "library",
            local_root: "/tmp/library",
            local_root_name: "library",
            local_path: "/tmp/library"
        }

        %{s | user_state: user_state}
      end)

      press(pid, "enter")
      assert_receive {TestLocalFiles, task, "/tmp/library/gone"}, 1_000
      send(task, {:result, {:error, "gone"}})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :videos
      assert state.local_path == "/tmp/library"
      assert state.videos == [directory]
      assert {:error, _} = state.status
    end

    test "canceling a child read restores the exact current folder" do
      pid = start_tui()

      directory = %{
        kind: :directory,
        id: "/tmp/library/season",
        title: "season",
        path: "/tmp/library/season"
      }

      :sys.replace_state(pid, fn s ->
        user_state = %{
          s.user_state
          | view: :locals,
            mode: :videos,
            videos: [directory],
            selected: 0,
            filter: "season",
            channel_name: "library",
            local_root: "/tmp/library",
            local_root_name: "library",
            local_path: "/tmp/library"
        }

        %{s | user_state: user_state}
      end)

      press(pid, "enter")
      assert_receive {TestLocalFiles, task, "/tmp/library/season"}, 1_000
      press(pid, "esc")

      state = user_state(pid)
      assert state.mode == :videos
      assert state.videos == [directory]
      assert state.local_path == "/tmp/library"
      assert state.filter == "season"
      assert state.selected == 0
      refute Process.alive?(task)
    end

    test "r refreshes the current folder and preserves filter and selected entry" do
      pid = start_tui()

      ep1 = %{
        kind: :file,
        id: "/tmp/library/season/ep1.mp4",
        title: "ep1.mp4",
        url: "/tmp/library/season/ep1.mp4"
      }

      ep2 = %{
        kind: :file,
        id: "/tmp/library/season/ep2.mp4",
        title: "ep2.mp4",
        url: "/tmp/library/season/ep2.mp4"
      }

      parent = %{path: "/tmp/library", name: "library", entries: [], selected: 0, filter: ""}

      :sys.replace_state(pid, fn s ->
        user_state = %{
          s.user_state
          | view: :locals,
            mode: :videos,
            videos: [ep1, ep2],
            selected: 1,
            filter: "ep",
            channel_name: "season",
            local_root: "/tmp/library",
            local_root_name: "library",
            local_path: "/tmp/library/season",
            local_stack: [parent]
        }

        %{s | user_state: user_state}
      end)

      press(pid, "r")
      assert_receive {TestLocalFiles, task, "/tmp/library/season"}, 1_000

      loading = user_state(pid)
      assert loading.mode == :loading
      assert loading.loading_return == :videos
      assert loading.local_pending.refresh
      assert loading.local_pending.selected_id == ep2.id
      assert {:info, "Refreshing season… (Esc to cancel)"} = loading.status
      assert Enum.member?(table_rows(TUI.render(loading, frame())), ["ep1.mp4", "File"])
      assert Enum.member?(table_rows(TUI.render(loading, frame())), ["ep2.mp4", "File"])

      ep0 = %{
        kind: :file,
        id: "/tmp/library/season/ep0.mp4",
        title: "ep0.mp4",
        url: "/tmp/library/season/ep0.mp4"
      }

      send(task, {:entries, [ep0, ep1, ep2]})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :videos
      assert state.videos == [ep0, ep1, ep2]
      assert state.local_path == "/tmp/library/season"
      assert state.local_stack == [parent]
      assert state.filter == "ep"
      assert state.selected == 2
      assert {:info, "Refreshed: 3 files in season"} = state.status
    end

    test "refresh clamps the cursor when the selected entry disappears" do
      pid = start_tui()
      first = %{kind: :file, id: "/tmp/v/a.mp4", title: "a.mp4", url: "/tmp/v/a.mp4"}
      removed = %{kind: :file, id: "/tmp/v/b.mp4", title: "b.mp4", url: "/tmp/v/b.mp4"}

      :sys.replace_state(pid, fn s ->
        user_state = %{
          s.user_state
          | view: :locals,
            mode: :videos,
            videos: [first, removed],
            selected: 1,
            channel_name: "v",
            local_root: "/tmp/v",
            local_root_name: "v",
            local_path: "/tmp/v"
        }

        %{s | user_state: user_state}
      end)

      press(pid, "r")
      assert_receive {TestLocalFiles, task, "/tmp/v"}, 1_000
      send(task, {:entries, [first]})
      _ = :sys.get_state(pid)

      assert user_state(pid).videos == [first]
      assert user_state(pid).selected == 0
    end

    test "canceling refresh preserves the frame and rejects its stale result" do
      pid = start_tui()
      file = %{kind: :file, id: "/tmp/v/a.mp4", title: "a.mp4", url: "/tmp/v/a.mp4"}
      parent = %{path: "/tmp", name: "tmp", entries: [], selected: 0, filter: ""}

      :sys.replace_state(pid, fn s ->
        user_state = %{
          s.user_state
          | view: :locals,
            mode: :videos,
            videos: [file],
            selected: 0,
            filter: "a",
            channel_name: "v",
            local_root: "/tmp/v",
            local_root_name: "v",
            local_path: "/tmp/v",
            local_stack: [parent]
        }

        %{s | user_state: user_state}
      end)

      press(pid, "r")
      assert_receive {TestLocalFiles, first_task, "/tmp/v"}, 1_000
      first_ref = user_state(pid).local_request_ref
      press(pid, "esc")

      state = user_state(pid)
      assert state.mode == :videos
      assert state.videos == [file]
      assert state.filter == "a"
      assert state.local_stack == [parent]
      refute Process.alive?(first_task)

      press(pid, "r")
      assert_receive {TestLocalFiles, second_task, "/tmp/v"}, 1_000
      second_ref = user_state(pid).local_request_ref

      stale = [
        %{kind: :file, id: "/tmp/v/stale.mp4", title: "stale.mp4", url: "/tmp/v/stale.mp4"}
      ]

      send(pid, {:local_entries_result, first_ref, {:ok, stale}})
      _ = :sys.get_state(pid)

      assert user_state(pid).mode == :loading
      assert user_state(pid).local_request_ref == second_ref
      assert user_state(pid).videos == [file]
      send(second_task, {:entries, [file]})
    end

    test "a failed root refresh keeps cached rows and reports it unavailable" do
      local = insert_local("/tmp/v", "v")
      pid = start_tui()
      file = %{kind: :file, id: "/tmp/v/a.mp4", title: "a.mp4", url: "/tmp/v/a.mp4"}

      :sys.replace_state(pid, fn s ->
        user_state = %{
          s.user_state
          | view: :locals,
            mode: :videos,
            videos: [file],
            channel_name: "v",
            local_root: "/tmp/v",
            local_root_name: "v",
            local_path: "/tmp/v"
        }

        %{s | user_state: user_state}
      end)

      press(pid, "r")
      assert_receive {TestLocalFiles, task, "/tmp/v"}, 1_000
      send(task, {:result, {:error, "could not read /tmp/v: no such file or directory"}})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :videos
      assert state.videos == [file]

      assert {:error,
              ~s(Local directory "v" is offline or unavailable: could not read /tmp/v: no such file or directory)} =
               state.status

      assert Enum.map(Playmark.Locals.list_locals(), & &1.id) == [local.id]
    end

    test "a successful local add result switches to the locals view and refreshes" do
      pid = start_tui()
      local = insert_local("/tmp/added", "added")
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :fetching}} end)

      send(pid, {:add_result, {:ok, local}, :local})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.view == :locals
      assert state.mode == :list
      assert {:info, "Added: added"} = state.status
      assert length(state.locals) == 1
    end

    test "Enter on a local file plays via play_local without blocking" do
      test_pid = self()
      Application.put_env(:playmark, :playback_impl, TestPlayback)
      Application.put_env(:playmark, :test_playback_pid, test_pid)
      on_exit(fn -> Application.delete_env(:playmark, :playback_impl) end)

      pid = start_tui()
      file = %{kind: :file, id: "/tmp/v/a.mp4", title: "a.mp4", url: "/tmp/v/a.mp4"}
      parent = %{path: "/tmp/v", name: "v", entries: [], selected: 0, filter: ""}

      :sys.replace_state(pid, fn s ->
        user_state = %{
          s.user_state
          | view: :locals,
            mode: :videos,
            videos: [file],
            local_root: "/tmp/v",
            local_root_name: "v",
            local_path: "/tmp/v/season",
            local_stack: [parent]
        }

        %{s | user_state: user_state}
      end)

      press(pid, "enter")
      assert user_state(pid).mode == :playing

      # play_local/3 on the stub announced itself; release it.
      assert_receive {TestPlayback, play_task}, 1_000
      send(play_task, :close)
      _ = :sys.get_state(pid)
      assert user_state(pid).mode == :videos
      assert user_state(pid).local_path == "/tmp/v/season"
      assert user_state(pid).local_stack == [parent]
    end

    test "b in :videos mode is a no-op for local files (can't bookmark)" do
      pid = start_tui()
      file = %{kind: :file, id: "/tmp/v/a.mp4", title: "a.mp4", url: "/tmp/v/a.mp4"}

      :sys.replace_state(pid, fn s ->
        %{s | user_state: %{s.user_state | view: :locals, mode: :videos, videos: [file]}}
      end)

      press(pid, "b")
      state = user_state(pid)
      assert state.mode == :videos
      assert {:info, "Bookmarking is for YouTube videos only"} = state.status
      assert Playmark.Bookmarks.list_bookmarks() == []
    end

    test "local browser renders entry types under a breadcrumb title" do
      state = %{
        view: :locals,
        mode: :videos,
        bookmarks: [],
        subscriptions: [],
        locals: [],
        playlists: [],
        videos: [
          %{kind: :directory, id: "/tmp/v/season", title: "season", path: "/tmp/v/season"},
          %{kind: :file, id: "/tmp/v/a.mp4", title: "a.mp4", url: "/tmp/v/a.mp4"}
        ],
        channel_name: "videos",
        local_root: "/tmp/v",
        local_root_name: "videos",
        local_path: "/tmp/v",
        selected: 0,
        filter: "",
        input: nil,
        status: {:info, "1 file in videos"}
      }

      widgets = TUI.render(state, %ExRatatui.Frame{width: 80, height: 24})

      assert Enum.member?(block_titles(widgets), " videos ")
      assert Enum.member?(table_rows(widgets), ["season", "Folder"])
      assert Enum.member?(table_rows(widgets), ["a.mp4", "File"])

      footer = footer_text(TUI.render(%{state | status: nil}, frame()))
      assert footer =~ "r: refresh"

      filtered_footer = footer_text(TUI.render(%{state | status: nil, filter: "a"}, frame()))
      assert filtered_footer =~ "r: refresh"
    end

    test "e on a folder does not enqueue it" do
      pid = start_tui()
      folder = %{kind: :directory, id: "/tmp/v/season", title: "season", path: "/tmp/v/season"}

      :sys.replace_state(pid, fn s ->
        %{s | user_state: %{s.user_state | view: :locals, mode: :videos, videos: [folder]}}
      end)

      press(pid, "e")
      assert user_state(pid).queue == []
      assert {:info, "Only media files can be queued"} = user_state(pid).status
    end
  end

  describe "playlists view" do
    setup do
      Application.put_env(:playmark, :youtube_playlist_impl, TestYouTubePlaylist)
      Application.put_env(:playmark, :test_youtube_playlist_pid, self())

      on_exit(fn ->
        Application.delete_env(:playmark, :youtube_playlist_impl)
        Application.delete_env(:playmark, :test_youtube_playlist_pid)
      end)
    end

    defp to_playlists(pid) do
      press(pid, "tab")
      press(pid, "tab")
      assert user_state(pid).view == :playlists
    end

    defp insert_youtube_playlist(id, title \\ "Lessons") do
      Repo.insert!(%Playmark.Playlist{
        url: "https://www.youtube.com/playlist?list=#{id}",
        title: title,
        channel: "Teacher"
      })
    end

    test "a opens the playlist URL prompt" do
      pid = start_tui()
      to_playlists(pid)
      press(pid, "a")
      assert user_state(pid).mode == :input
    end

    test "Enter loads current entries without blocking" do
      playlist = insert_youtube_playlist("PL123")
      pid = start_tui()
      to_playlists(pid)

      press(pid, "enter")
      state = user_state(pid)
      assert state.mode == :loading
      assert is_reference(state.playlist_request_ref)
      assert_receive {TestYouTubePlaylist, task, url}, 1_000
      assert url == playlist.url

      videos = [
        %{
          id: "abcdefghijk",
          title: "Episode 1",
          url: "https://www.youtube.com/watch?v=abcdefghijk",
          author: "Teacher",
          live: :none
        }
      ]

      send(task, {:videos, videos})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :videos
      assert state.videos == videos
      assert state.channel_name == "Lessons"
      assert state.playlist_request_ref == nil
      assert {:info, "1 video from Lessons"} = state.status
    end

    test "an empty or failed playlist reports its outcome" do
      insert_youtube_playlist("PL123")
      pid = start_tui()
      to_playlists(pid)

      press(pid, "enter")
      assert_receive {TestYouTubePlaylist, empty_task, _url}, 1_000
      send(empty_task, {:videos, []})
      _ = :sys.get_state(pid)
      assert user_state(pid).mode == :videos
      assert {:info, "No available videos in Lessons"} = user_state(pid).status

      press(pid, "esc")
      press(pid, "enter")
      assert_receive {TestYouTubePlaylist, failed_task, _url}, 1_000
      send(failed_task, {:result, {:error, "private"}})
      _ = :sys.get_state(pid)
      assert user_state(pid).mode == :list
      assert {:error, "Could not load playlist: private"} = user_state(pid).status
    end

    test "a canceled playlist result is dropped" do
      insert_youtube_playlist("PL123")
      pid = start_tui()
      to_playlists(pid)
      press(pid, "enter")
      assert_receive {TestYouTubePlaylist, task, _url}, 1_000

      press(pid, "esc")
      send(task, {:videos, [%{title: "Late", url: "https://youtu.be/abcdefghijk"}]})
      _ = :sys.get_state(pid)

      assert user_state(pid).mode == :list
      assert user_state(pid).videos == []
    end

    test "playlist videos queue as YouTube content while the container does not" do
      insert_youtube_playlist("PL123")
      pid = start_tui()
      to_playlists(pid)

      press(pid, "e")
      assert user_state(pid).queue == []

      video = %{
        title: "Episode",
        url: "https://www.youtube.com/watch?v=abcdefghijk",
        author: "Teacher"
      }

      :sys.replace_state(pid, fn state ->
        %{state | user_state: %{state.user_state | mode: :videos, videos: [video]}}
      end)

      press(pid, "e")
      assert [item] = user_state(pid).queue
      assert item.local == false
      assert item.author == "Teacher"
    end

    test "a successful add result refreshes the Playlists view" do
      playlist = insert_youtube_playlist("PL123")
      pid = start_tui()

      :sys.replace_state(pid, fn state ->
        %{state | user_state: %{state.user_state | mode: :fetching}}
      end)

      send(pid, {:add_result, {:ok, playlist}, :playlist})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.view == :playlists
      assert state.mode == :list
      assert state.playlists == [playlist]
      assert {:info, "Added: Lessons"} = state.status
    end

    test "renders saved playlists and opened playlist videos" do
      playlist = %Playmark.Playlist{title: "Lessons", channel: "Teacher", url: "u"}

      state = %{
        view: :playlists,
        mode: :list,
        playlists: [playlist],
        locals: [],
        selected: 0,
        filter: "",
        status: nil
      }

      widgets = TUI.render(state, frame())
      assert Enum.member?(block_titles(widgets), " Playlists ")
      assert Enum.member?(table_rows(widgets), ["Lessons", "Teacher"])
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
      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        playing = %{
          ref: ref,
          title: "V",
          player: :vlc,
          steps: [:resolving, :playing],
          stage: :resolving,
          captions: %{default: "en", fallback: nil, result: nil},
          stream: %{max_height: 1080, result: nil}
        }

        %{s | user_state: %{s.user_state | mode: :playing, playing: playing}}
      end)

      send(pid, {:play_progress, ref, {:stream, :split}})
      _ = :sys.get_state(pid)

      playing = user_state(pid).playing
      # The concrete shape is recorded; the stage marker is unchanged.
      assert playing.stream.result == :split
      assert playing.stage == :resolving
    end

    test "a :play_progress message advances the stage in state" do
      pid = start_tui()
      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        playing = %{
          ref: ref,
          title: "V",
          player: :mpv,
          steps: [:captions, :playing],
          stage: :starting,
          captions: %{default: "en", fallback: nil, result: nil}
        }

        %{s | user_state: %{s.user_state | mode: :playing, playing: playing}}
      end)

      send(pid, {:play_progress, ref, :captions})
      _ = :sys.get_state(pid)

      assert user_state(pid).playing.stage == :captions
    end

    test "a :caption result folds into the playing map and stays on the captions stage" do
      pid = start_tui()
      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        playing = %{
          ref: ref,
          title: "V",
          player: :mpv,
          steps: [:captions, :playing],
          stage: :captions,
          captions: %{default: "en", fallback: nil, result: nil}
        }

        %{s | user_state: %{s.user_state | mode: :playing, playing: playing}}
      end)

      send(pid, {:play_progress, ref, {:caption, {:auto, "id"}}})
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
      send(pid, {:play_progress, make_ref(), :playing})
      _ = :sys.get_state(pid)

      assert user_state(pid).mode == :list
    end
  end

  describe "Explore" do
    setup do
      Application.put_env(:playmark, :explore_impl, TestExplore)
      Application.put_env(:playmark, :test_explore_pid, self())

      on_exit(fn ->
        Application.delete_env(:playmark, :explore_impl)
        Application.delete_env(:playmark, :test_explore_pid)
        Application.delete_env(:playmark, :playback_impl)
        Application.delete_env(:playmark, :test_playback_pid)
      end)
    end

    test "E starts a non-blocking homepage fetch and opens Explore" do
      pid = start_tui()

      press(pid, "E")
      state = user_state(pid)
      assert state.mode == :explore_loading
      assert state.explore_return == :list
      assert is_reference(state.explore_request_ref)
      assert is_pid(state.explore_task_pid)

      assert_receive {TestExplore, task}, 1_000

      videos = [
        %{
          id: "abcdefghijk",
          title: "Recommended",
          url: "https://youtu.be/abcdefghijk",
          author: "Channel"
        }
      ]

      send(task, {:videos, videos})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :explore
      assert state.explore_videos == videos
      assert state.explore_selected == 0
      assert state.explore_request_ref == nil
      assert state.explore_task_pid == nil
      assert {:info, "1 recommendation"} = state.status
    end

    test "Esc restores the video list that Explore was opened over" do
      pid = start_tui()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | view: :locals,
                mode: :videos,
                videos: [%{title: "clip.mp4", url: "/tmp/clip.mp4"}],
                local_root: "/tmp",
                local_root_name: "tmp",
                local_path: "/tmp/season",
                local_stack: [%{path: "/tmp", entries: [], selected: 0, filter: ""}],
                selected: 0
            }
        }
      end)

      press(pid, "E")
      assert_receive {TestExplore, task}, 1_000
      send(task, {:videos, [%{title: "Online", url: "https://youtu.be/abcdefghijk"}]})
      _ = :sys.get_state(pid)
      press(pid, "esc")

      state = user_state(pid)
      assert state.mode == :videos
      assert state.view == :locals
      assert state.videos == [%{title: "clip.mp4", url: "/tmp/clip.mp4"}]
      assert state.local_path == "/tmp/season"
      assert length(state.local_stack) == 1
    end

    test "empty and failed fetches report their outcomes" do
      pid = start_tui()
      press(pid, "E")
      assert_receive {TestExplore, empty_task}, 1_000
      send(empty_task, {:videos, []})
      _ = :sys.get_state(pid)

      assert user_state(pid).mode == :explore
      assert {:info, "No recommendations found"} = user_state(pid).status

      press(pid, "esc")
      press(pid, "E")
      assert_receive {TestExplore, failed_task}, 1_000
      send(failed_task, {:result, {:error, "unavailable"}})
      _ = :sys.get_state(pid)

      assert user_state(pid).mode == :list
      assert {:error, "Explore failed: unavailable"} = user_state(pid).status
    end

    test "Esc cancels loading and drops its late result" do
      pid = start_tui()
      press(pid, "E")
      assert_receive {TestExplore, task}, 1_000

      press(pid, "esc")
      assert user_state(pid).mode == :list
      assert user_state(pid).explore_request_ref == nil
      assert user_state(pid).explore_task_pid == nil
      refute Process.alive?(task)

      send(task, {:videos, [%{title: "Too late", url: "https://youtu.be/abcdefghijk"}]})
      _ = :sys.get_state(pid)

      assert user_state(pid).mode == :list
      assert user_state(pid).explore_videos == []
    end

    test "a canceled request cannot replace a newer Explore request" do
      pid = start_tui()
      press(pid, "E")
      assert_receive {TestExplore, old_task}, 1_000
      old_ref = user_state(pid).explore_request_ref

      press(pid, "esc")
      press(pid, "E")
      assert_receive {TestExplore, new_task}, 1_000
      new_ref = user_state(pid).explore_request_ref
      refute new_ref == old_ref

      send(old_task, {:videos, [%{title: "Old", url: "https://youtu.be/abcdefghijk"}]})
      _ = :sys.get_state(pid)
      assert user_state(pid).mode == :explore_loading
      assert user_state(pid).explore_request_ref == new_ref

      send(new_task, {:videos, [%{title: "New", url: "https://youtu.be/123456789_-"}]})
      _ = :sys.get_state(pid)
      assert [%{title: "New"}] = user_state(pid).explore_videos
    end

    test "j/k navigate recommendations within bounds" do
      pid = start_tui()
      videos = Enum.map(["A", "B", "C"], &%{title: &1, url: "https://youtu.be/abcdefghijk"})

      :sys.replace_state(pid, fn s ->
        %{s | user_state: %{s.user_state | mode: :explore, explore_videos: videos}}
      end)

      press(pid, "k")
      assert user_state(pid).explore_selected == 0
      press(pid, "j")
      press(pid, "j")
      press(pid, "j")
      assert user_state(pid).explore_selected == 2
    end

    test "e queues an Explore recommendation as YouTube content" do
      pid = start_tui()
      video = %{title: "Online", url: "https://youtu.be/abcdefghijk", author: "Channel"}

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{s.user_state | view: :locals, mode: :explore, explore_videos: [video]}
        }
      end)

      press(pid, "e")

      assert [item] = user_state(pid).queue
      assert item.url == video.url
      assert item.local == false
      assert item.author == "Channel"
    end

    test "n inserts an Explore recommendation right after the queue head" do
      {:ok, _} = Queue.enqueue(%{title: "Head", url: "u-head", local: false})
      pid = start_tui()
      video = %{title: "Play Me Next", url: "https://youtu.be/abcdefghijk", author: "Channel"}

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{s.user_state | view: :locals, mode: :explore, explore_videos: [video]}
        }
      end)

      press(pid, "n")

      assert Enum.map(user_state(pid).queue, & &1.title) == ["Head", "Play Me Next"]
    end

    test "Enter plays Explore content as non-local and returns to Explore" do
      Application.put_env(:playmark, :playback_impl, TestPlayback)
      Application.put_env(:playmark, :test_playback_pid, self())
      pid = start_tui()
      video = %{title: "Online", url: "https://youtu.be/abcdefghijk", author: "Channel"}

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{s.user_state | view: :locals, mode: :explore, explore_videos: [video]}
        }
      end)

      press(pid, "enter")
      state = user_state(pid)
      assert state.mode == :playing
      assert state.playing.origin == :explore
      assert [entry] = History.list_items()
      assert entry.local == false
      assert entry.author == "Channel"

      assert_receive {TestPlayback, play_task}, 1_000
      send(play_task, :close)
      _ = :sys.get_state(pid)
      assert user_state(pid).mode == :explore
    end

    test "Queue and History overlays close back to Explore" do
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :explore}} end)

      press(pid, "Q")
      assert user_state(pid).queue_return == :explore
      press(pid, "esc")
      assert user_state(pid).mode == :explore

      press(pid, "H")
      assert user_state(pid).history_return == :explore
      press(pid, "esc")
      assert user_state(pid).mode == :explore
    end

    test "a Queue started from Explore returns there when it finishes" do
      Application.put_env(:playmark, :playback_impl, TestPlayback)
      Application.put_env(:playmark, :test_playback_pid, self())
      {:ok, _} = Queue.enqueue(%{title: "Queued", url: "https://youtu.be/abcdefghijk"})
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: %{s.user_state | mode: :explore}} end)

      press(pid, "Q")
      press(pid, "enter")
      assert user_state(pid).playing.return_mode == :explore
      assert_receive {TestPlayback, play_task}, 1_000

      send(play_task, :close)
      _ = :sys.get_state(pid)

      assert user_state(pid).mode == :explore
      assert user_state(pid).queue == []
    end

    test "a Queue failure opened from Explore keeps Explore as the modal return" do
      {:ok, item} = Queue.enqueue(%{title: "Queued", url: "https://youtu.be/abcdefghijk"})
      pid = start_tui()
      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | mode: :playing,
                queue_return: :explore,
                playing: %{
                  ref: ref,
                  title: "Queued",
                  origin: :queue,
                  queue_id: item.id,
                  return_mode: :explore
                }
            }
        }
      end)

      send(pid, {:play_result, ref, {:error, "failed"}})
      _ = :sys.get_state(pid)

      assert user_state(pid).mode == :queue_manage
      assert user_state(pid).queue_return == :explore
      press(pid, "esc")
      assert user_state(pid).mode == :explore
    end

    test "renders the Explore overlay and its controls" do
      pid = start_tui()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | mode: :explore,
                explore_videos: [%{title: "Recommended", url: "https://youtu.be/abcdefghijk"}],
                status: nil
            }
        }
      end)

      widgets = TUI.render(user_state(pid), frame())
      assert Enum.member?(block_titles(widgets), " Explore ")
      assert footer_text(widgets) =~ "b: bookmark"
      assert footer_text(widgets) =~ "Q: queue | H: history"
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
      # Drive the Locals view to a populated video list via the stub, then queue.
      Application.put_env(:playmark, :local_files_impl, TestLocalFiles)
      Application.put_env(:playmark, :test_local_files_pid, self())

      on_exit(fn ->
        Application.delete_env(:playmark, :local_files_impl)
        Application.delete_env(:playmark, :test_local_files_pid)
      end)

      pid = start_tui()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | view: :locals,
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
      pid = start_tui()

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

      footer = footer_text(TUI.render(user_state(pid), frame()))
      refute footer =~ "Enter: play"
      assert footer =~ "q: quit"

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
      assert staged.confirm.prompt == "Clear all 1 queued item?"

      [{header, _rect} | _] = TUI.render(staged, frame())
      assert header.text == "playmark — Queue"

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
      ref = make_ref()

      # Enter :playing on the head with origin :queue.
      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | mode: :playing,
                queue: Queue.list_items(),
                playing: %{ref: ref, title: "First", origin: :queue, queue_id: first.id}
            }
        }
      end)

      send(pid, {:play_result, ref, {:ok, :completed}})
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
      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | mode: :playing,
                queue: Queue.list_items(),
                playing: %{ref: ref, title: "Only", origin: :queue, queue_id: only.id}
            }
        }
      end)

      send(pid, {:play_result, ref, {:ok, :completed}})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :list
      assert state.queue == []
      assert {:info, "Queue finished"} = state.status
    end

    test "closing a queued mpv or VLC play early keeps the item and stops the queue" do
      {:ok, first} = Queue.enqueue(%{title: "Partial", url: "u-1", local: false})
      {:ok, _next} = Queue.enqueue(%{title: "Next", url: "u-2", local: false})
      pid = start_tui()
      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        playing = %{
          ref: ref,
          title: "Partial",
          player: :vlc,
          origin: :queue,
          queue_id: first.id,
          return_mode: :list
        }

        %{s | user_state: %{s.user_state | mode: :playing, playing: playing}}
      end)

      send(pid, {:play_result, ref, {:ok, :stopped}})
      _ = :sys.get_state(pid)

      state = user_state(pid)
      assert state.mode == :queue_manage
      assert Enum.map(state.queue, & &1.title) == ["Partial", "Next"]
      assert {:info, "Playback stopped; progress saved"} = state.status
    end

    test "a queued item failing stops the queue and shows the modal" do
      {:ok, bad} = Queue.enqueue(%{title: "Bad", url: "u-1", local: false})
      {:ok, _next} = Queue.enqueue(%{title: "Next", url: "u-2", local: false})
      pid = start_tui()
      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | mode: :playing,
                queue: Queue.list_items(),
                playing: %{ref: ref, title: "Bad", origin: :queue, queue_id: bad.id}
            }
        }
      end)

      send(pid, {:play_result, ref, {:error, "vlc exited with 1"}})
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

  defp input_widget(widgets) do
    {widget, _rect} = Enum.at(widgets, 2)
    widget
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
      assert staged.confirm.prompt == "Clear all 1 history entry?"

      [{header, _rect} | _] = TUI.render(staged, frame())
      assert header.text == "playmark — History"

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

    test "e appends the selected history entry to the queue tail" do
      Enum.each(["A", "B"], fn t -> {:ok, _} = History.record(%{title: t, url: "u-#{t}"}) end)
      pid = start_tui()
      press(pid, "H")

      # History lists newest first, so the head is "B"; enqueue it, then "A".
      press(pid, "e")
      press(pid, "j")
      press(pid, "e")

      assert Enum.map(Queue.list_items(), & &1.title) == ["B", "A"]
      assert user_state(pid).mode == :history
    end

    test "n inserts the selected history entry right after the queue head" do
      {:ok, _} = Queue.enqueue(%{title: "Head", url: "u-head", local: false})
      {:ok, _} = History.record(%{title: "Next Up", url: "u-next"})
      pid = start_tui()
      press(pid, "H")

      press(pid, "n")

      assert Enum.map(Queue.list_items(), & &1.title) == ["Head", "Next Up"]
    end
  end

  describe "help overlay" do
    test "? opens help from :list and Esc restores the prior mode" do
      pid = start_tui()

      press(pid, "?")
      assert user_state(pid).mode == :help
      assert user_state(pid).help_return == :list

      press(pid, "esc")
      assert user_state(pid).mode == :list
    end

    test "? closes the help overlay again" do
      pid = start_tui()

      press(pid, "?")
      assert user_state(pid).mode == :help

      press(pid, "?")
      assert user_state(pid).mode == :list
    end

    test "help opens over an opened video list and returns to it" do
      state = %{user_state(start_tui()) | mode: :videos, videos: [], videos_return: :list}
      pid = start_tui()
      :sys.replace_state(pid, fn s -> %{s | user_state: state} end)

      press(pid, "?")
      assert user_state(pid).mode == :help
      assert user_state(pid).help_return == :videos

      press(pid, "esc")
      assert user_state(pid).mode == :videos
    end

    test "the help body lists representative keys and titles itself" do
      pid = start_tui()
      press(pid, "?")

      widgets = TUI.render(user_state(pid), frame())
      assert body_text(widgets) =~ "n: play next"
      assert body_text(widgets) =~ "?: this help"
      assert "Help" in block_titles(widgets) or " Help " in block_titles(widgets)
    end
  end

  describe "filter" do
    defp seed_bookmarks do
      Repo.insert!(%Bookmark{url: "https://youtu.be/1", title: "Elixir Basics", channel: "Alpha"})

      Repo.insert!(%Bookmark{
        url: "https://youtu.be/2",
        title: "Erlang Deep Dive",
        channel: "Beta"
      })

      Repo.insert!(%Bookmark{
        url: "https://youtu.be/3",
        title: "Phoenix LiveView",
        channel: "Alpha"
      })
    end

    test "\"/\" enters :filter mode from a browse list" do
      seed_bookmarks()
      pid = start_tui()

      press(pid, "/")
      assert user_state(pid).mode == :filter
      assert user_state(pid).filter_return == :list
    end

    test "typing narrows the current list and clamps the selection" do
      seed_bookmarks()
      pid = start_tui()

      # Move down first, then filter to a single match — selection must clamp.
      press(pid, "j")
      press(pid, "j")
      assert user_state(pid).selected == 2

      press(pid, "/")
      type(pid, "elixir")

      state = user_state(pid)
      assert state.filter == "elixir"
      # Only "Elixir Basics" survives, so selection clamps to 0.
      assert state.selected == 0
    end

    test "matching is case-insensitive across the secondary column" do
      seed_bookmarks()
      pid = start_tui()

      press(pid, "/")
      type(pid, "ALPHA")

      # Filter runs over [:title, :channel]; two rows have channel "Alpha".
      assert Playmark.TUI.Filter.visible(user_state(pid)) |> length() == 2
    end

    test "backspace shortens the term and re-widens the list" do
      seed_bookmarks()
      pid = start_tui()

      press(pid, "/")
      type(pid, "erlang")
      assert Playmark.TUI.Filter.visible(user_state(pid)) |> length() == 1

      press(pid, "backspace")
      assert user_state(pid).filter == "erlan"
    end

    test "the block cursor supports correcting a filter in the middle" do
      seed_bookmarks()
      pid = start_tui()

      press(pid, "/")
      type(pid, "elixr")
      press(pid, "left")
      assert ExRatatui.text_input_cursor(user_state(pid).input) == 4

      input_widget = input_widget(TUI.render(user_state(pid), frame()))
      assert :reversed in input_widget.cursor_style.modifiers

      type(pid, "i")
      assert user_state(pid).filter == "elixir"
      assert Playmark.TUI.Filter.visible(user_state(pid)) |> length() == 1
    end

    test "Enter closes the field keeping the term" do
      seed_bookmarks()
      pid = start_tui()

      press(pid, "/")
      type(pid, "elixir")
      press(pid, "enter")

      state = user_state(pid)
      assert state.mode == :list
      assert state.filter == "elixir"
    end

    test "Esc closes the field keeping the term" do
      seed_bookmarks()
      pid = start_tui()

      press(pid, "/")
      type(pid, "elixir")
      press(pid, "esc")

      state = user_state(pid)
      assert state.mode == :list
      assert state.filter == "elixir"
    end

    test "reopening the field prefills the current term" do
      seed_bookmarks()
      pid = start_tui()

      press(pid, "/")
      type(pid, "eli")
      press(pid, "esc")
      press(pid, "/")

      assert user_state(pid).filter == "eli"
      assert ExRatatui.text_input_get_value(user_state(pid).input) == "eli"
      assert ExRatatui.text_input_cursor(user_state(pid).input) == 3
    end

    test "Esc in the base list clears an active filter" do
      seed_bookmarks()
      pid = start_tui()

      press(pid, "/")
      type(pid, "elixir")
      press(pid, "enter")
      assert user_state(pid).filter == "elixir"

      press(pid, "esc")
      state = user_state(pid)
      assert state.filter == ""
      assert state.selected == 0
    end

    test "Enter plays the filtered selection, not the unfiltered one" do
      Application.put_env(:playmark, :playback_impl, TestPlayback)
      Application.put_env(:playmark, :test_playback_pid, self())

      on_exit(fn ->
        Application.delete_env(:playmark, :playback_impl)
        Application.delete_env(:playmark, :test_playback_pid)
      end)

      seed_bookmarks()
      pid = start_tui()

      # Filter to the single "Phoenix" row; it becomes index 0 of the filtered list.
      press(pid, "/")
      type(pid, "phoenix")
      press(pid, "enter")
      press(pid, "enter")

      state = user_state(pid)
      assert state.mode == :playing
      # The panel is seeded from the selected item — proving Enter resolved the
      # filtered selection ("Phoenix LiveView"), not the original index-0 row.
      assert state.playing.title == "Phoenix LiveView"

      assert_receive {TestPlayback, play_task}, 1_000
      send(play_task, :close)
    end

    test "d deletes the filtered selection" do
      seed_bookmarks()
      pid = start_tui()

      press(pid, "/")
      type(pid, "phoenix")
      press(pid, "enter")
      press(pid, "d")
      press(pid, "y")

      titles = Enum.map(user_state(pid).bookmarks, & &1.title)
      refute "Phoenix LiveView" in titles
      assert "Elixir Basics" in titles
    end

    test "Tab resets an active filter" do
      seed_bookmarks()
      pid = start_tui()

      press(pid, "/")
      type(pid, "elixir")
      press(pid, "enter")
      assert user_state(pid).filter == "elixir"

      press(pid, "tab")
      assert user_state(pid).filter == ""
    end

    test "S opens Search while slash remains the list filter" do
      pid = start_tui()

      press(pid, "/")
      assert user_state(pid).mode == :filter
      press(pid, "esc")

      press(pid, "S")
      assert user_state(pid).mode == :search_input
    end

    test "leaving a channel's video list resets the filter" do
      pid = start_tui()

      videos = [%{id: "a", title: "One", url: "u1"}, %{id: "b", title: "Two", url: "u2"}]

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | view: :subscriptions,
                mode: :videos,
                videos: videos,
                channel_name: "Chan",
                filter: "one"
            }
        }
      end)

      # First Esc clears the filter (stays in :videos), second leaves the list.
      press(pid, "esc")
      assert user_state(pid).mode == :videos
      assert user_state(pid).filter == ""

      press(pid, "esc")
      assert user_state(pid).mode == :list
    end

    test "a fresh video result clears any leftover filter term" do
      pid = start_tui()
      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | user_state: %{
              s.user_state
              | mode: :loading,
                filter: "stale",
                channel_request_ref: ref
            }
        }
      end)

      videos = [%{id: "x", title: "Vid X", url: "u"}]
      send(pid, {:videos_result, ref, {:ok, videos}, "Chan", "https://youtube.com/@c", :videos})
      _ = :sys.get_state(pid)

      assert user_state(pid).filter == ""
    end
  end

  defp duplicate_local_changeset do
    path = "/tmp/playmark-dup-dir"
    Repo.insert!(%Playmark.Local{path: path, name: "dir"})

    {:error, changeset} =
      %Playmark.Local{}
      |> Playmark.Local.changeset(%{path: path, name: "dir"})
      |> Repo.insert()

    changeset
  end
end
