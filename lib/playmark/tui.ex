defmodule Playmark.TUI do
  @moduledoc """
  The playmark terminal UI.

  A LiveView-style ExRatatui app with four top-level views — Bookmarks,
  Subscriptions, Playlists, and Locals — cycled with `Tab`, and a mode state machine
  layered on top:

    * `:list`     — browse the current view's list. `j`/`k` move, `a` adds, `d` deletes
                    (via a `:confirm` prompt), `Tab` cycles view, `q` quits.
                    `Enter` plays a bookmark or opens a saved source.
    * `:input`    — type into a `TextInput` while adding a persisted item.
    * `:filter`   — type an incremental filter over the current browse list
                    (`:list` for bookmarks/subscriptions/playlists/locals, or `:videos`).
                    Opened with `/`; the list narrows as you type. `Enter`/`Esc`
                    close the field keeping the term; in the base mode `Esc`
                    clears an active filter.
    * `:fetching` — a background task is adding an item to a top-level view.
    * `:loading`  — a background task is listing a saved source.
    * `:videos`   — browse a subscription, playlist, or local directory.
                     `Enter` plays media or opens a local folder; `r` refreshes
                     that folder; `Esc` restores its parent/origin. On a direct subscription listing,
                     `s`/`v` switch Streams/Videos and `p` opens channel playlists.
    * `:channel_playlists_loading` / `:channel_playlists` /
      `:channel_playlists_filter` — fetch and browse a channel's non-playable
                     playlist containers. `Enter` opens one into `:videos`; `p`
                     saves it to the top-level Playlists view.
    * `:playing`  — the playback task is preparing or running the external
                     player; only `Q` is accepted until it finishes.
    * `:resume`   — a saved checkpoint is waiting for `y` (resume), `n` (start
                     over), or `Esc` (cancel). The originating page stays visible.
    * `:confirm`  — a destructive action (list `d` delete, queue/history `d`
                    single-item remove, or queue/history `c` clear) is staged
                    behind a `y`/`n` prompt; `y` performs it, any other key
                    cancels. The underlying list/queue/history stays on screen
                    with the prompt shown in the footer.
    * `:history`  — browse watch history (an overlay opened with `H` from
                    any browse mode, not over the player). `Enter` replays,
                     `d` removes one entry, `c` clears all (via `:confirm`),
                     `Esc` closes back to where it was opened.
    * `:explore_loading` / `:explore` — fetch and browse YouTube's recommended
                    feed, opened with `E` from a base/video/channel-playlist list.
                    Results are transient; `Esc` restores the underlying page.
    * `:search_input` / `:search_loading` / `:search_results` / `:search_filter`
                    — an isolated Search overlay opened with `S` from
                    a base/video/channel-playlist list. Its rows and filter never
                    replace the underlying page.

  Subscriptions store only the channel URL and name; channel tabs are fetched
  live through `Playmark.Source.Channel`. Discovered playlist containers remain
  transient unless the user saves one to the top-level Playlists view.

  Every operation that performs external I/O (adding, listing, playback) runs in
  a spawned task and reports back via `handle_info/2`, so the runtime never blocks.
  Fetching and loading states accept `Esc`; Search, Explore, local directories,
  channel tabs, and playlist loads match request references and terminate tracked
  tasks. Older add paths discard late results through mode guards.

  This module is the `ExRatatui.App` shell: it owns the runtime callbacks and
  routes work to two collaborators — `Playmark.TUI.Actions` for state
  transitions (key handling, navigation, task spawning) and `Playmark.TUI.View`
  for rendering.

  `Actions` holds the browse core — the list / videos / channel-playlists /
  filter / input state machine, which is one machine and not separable. The
  overlays and the shared plumbing live in sibling modules: `TUI.PlaybackActions`,
  `TUI.QueueActions`, `TUI.HistoryActions`, `TUI.SearchActions`,
  `TUI.ExploreActions`, `TUI.HelpActions`, `TUI.AddActions`, plus `TUI.Nav`
  (cursor math) and `TUI.Impl` (the test seams).
  """

  use ExRatatui.App

  alias ExRatatui.Event
  alias Playmark.{Bookmarks, History, Locals, Playlists, Queue, Subscriptions}

  alias Playmark.TUI.{
    Actions,
    AddActions,
    ExploreActions,
    Filter,
    HelpActions,
    HistoryActions,
    PlaybackActions,
    QueueActions,
    SearchActions,
    Status,
    View
  }

  @impl true
  def mount(_opts) do
    # The TextInput's editor state lives in a NIF resource: create it once here
    # and thread it through state. Rebuilding it in render/2 would wipe the
    # cursor and typed text every frame.
    input = ExRatatui.text_input_new()

    {:ok,
     %{
       view: :bookmarks,
       mode: :list,
       bookmarks: Bookmarks.list_bookmarks(),
       subscriptions: Subscriptions.list_subscriptions(),
       locals: Locals.list_locals(),
       playlists: Playlists.list_playlists(),
       queue: Queue.list_items(),
       videos: [],
       channel_name: nil,
       # The canonical URL of the channel whose videos are open (nil otherwise),
       # and which of its tabs is showing (:videos | :streams). Kept so the `s`/`v`
       # keys can re-fetch the other tab of the same channel (see Actions.switch_tab/2).
       channel_url: nil,
       video_tab: :videos,
       videos_return: :list,
       channel_request_ref: nil,
       channel_task_pid: nil,
       playlist_request_ref: nil,
       playlist_task_pid: nil,
       playlist_return: :list,
       loading_return: :list,
       # Local browsing stays in :videos but keeps a stack of parent snapshots so
       # Esc can restore the exact directory rows, cursor, and filter immediately.
       local_root: nil,
       local_root_name: nil,
       local_path: nil,
       local_stack: [],
       local_pending: nil,
       local_request_ref: nil,
       local_task_pid: nil,
       # Channel playlist containers are a nested, non-playable browse level.
       # Their cursor/filter survive while one playlist's videos are open.
       channel_playlists: [],
       channel_playlist_selected: 0,
       channel_playlist_filter: "",
       channel_playlist_channel_name: nil,
       channel_playlist_channel_url: nil,
       channel_playlists_return: :videos,
       channel_playlists_request_ref: nil,
       channel_playlists_task_pid: nil,
       channel_playlist_save_ref: nil,
       selected: 0,
       # The selection index inside the queue-manage modal, kept separate from
       # `selected` so opening/closing the modal doesn't disturb the base view's
       # cursor.
       queue_selected: 0,
       # The mode to restore when the queue-manage modal closes (the modal can be
       # opened from a browse mode or :playing).
       queue_return: :list,
       # Watch history (newest first), and — like the queue — a modal selection
       # index and the mode to restore when the history modal closes. The history
       # modal is reachable from any browse mode (not over the running player).
       history: History.list_items(),
       history_selected: 0,
       history_return: :list,
       # Explore is a transient YouTube homepage overlay. Its rows and cursor are
       # separate from `videos`/`selected`, so opening it never disturbs the list
       # underneath (and never inherits the Locals view's playback semantics).
       explore_videos: [],
       explore_selected: 0,
       explore_return: :list,
       explore_request_ref: nil,
       explore_task_pid: nil,
       # Search is an isolated overlay: its rows, cursor, filter, and request
       # lifecycle never overwrite the list underneath it.
       search_videos: [],
       search_selected: 0,
       search_query: "",
       search_filter: "",
       search_return: :list,
       search_request_ref: nil,
       search_task_pid: nil,
       # A pending destructive action awaiting y/n confirmation (%{action, prompt}),
       # nil outside :confirm mode; confirm_return is the mode to restore after.
       confirm: nil,
       confirm_return: :list,
       # A playable item waiting for the user to resume, start over, or cancel.
       resume: nil,
       input: input,
       # The active incremental filter term (empty = no filter) and the mode to
       # restore when the filter field closes (:list or :videos).
       filter: "",
       filter_return: :list,
       # The mode to restore when the help overlay closes. Like the queue/history
       # modals, help is a static overlay opened over a browse mode.
       help_return: :list,
       status: nil,
       playing: nil
     }}
  end

  # --- event routing -------------------------------------------------------

  # Only act on key presses; ignore key releases and auto-repeat.
  @impl true
  def handle_event(%Event.Key{kind: kind}, state) when kind != "press" do
    {:noreply, state}
  end

  # "Q" opens the queue manager from any browse mode, including Search and
  # Explore, or over the running player. It's the only key :playing accepts; see
  # the catch-all guard below.
  def handle_event(%Event.Key{code: "Q"}, %{mode: mode} = state)
      when mode in [:list, :videos, :channel_playlists, :search_results, :explore, :playing] do
    {:noreply, QueueActions.open_queue(state)}
  end

  def handle_event(%Event.Key{} = key, %{mode: :queue_manage} = state) do
    QueueActions.handle_queue_key(key.code, state)
  end

  # "H" opens watch history from any browse mode, including Search and Explore.
  # Unlike the queue's "Q", it is not accepted over the running player.
  def handle_event(%Event.Key{code: "H"}, %{mode: mode} = state)
      when mode in [:list, :videos, :channel_playlists, :search_results, :explore] do
    {:noreply, HistoryActions.open_history(state)}
  end

  def handle_event(%Event.Key{} = key, %{mode: :history} = state) do
    HistoryActions.handle_history_key(key.code, state)
  end

  # "?" opens the keybinding help overlay from any browse mode. `:help` is
  # deliberately excluded from the allow-list so pressing "?" again inside the
  # overlay falls through to the :help dispatch clause below, which closes it.
  def handle_event(%Event.Key{code: "?"}, %{mode: mode} = state)
      when mode in [:list, :videos, :channel_playlists, :search_results, :explore] do
    {:noreply, HelpActions.open_help(state)}
  end

  def handle_event(%Event.Key{} = key, %{mode: :help} = state) do
    HelpActions.handle_help_key(key.code, state)
  end

  # Explore behaves like the queue/history pages but fetches its transient rows
  # in the background each time it opens.
  def handle_event(%Event.Key{code: "E"}, %{mode: mode} = state)
      when mode in [:list, :videos, :channel_playlists] do
    {:noreply, ExploreActions.open_explore(state)}
  end

  def handle_event(%Event.Key{} = key, %{mode: :explore} = state) do
    ExploreActions.handle_explore_key(key.code, state)
  end

  # Search is a sibling of Explore and opens only over a base list or an opened
  # source list. Uppercase S remains distinct from lowercase s (Streams).
  def handle_event(%Event.Key{code: "S"}, %{mode: mode} = state)
      when mode in [:list, :videos, :channel_playlists] do
    {:noreply, SearchActions.open_search(state)}
  end

  def handle_event(%Event.Key{} = key, %{mode: :search_input} = state) do
    SearchActions.handle_search_input_key(key, state)
  end

  def handle_event(%Event.Key{} = key, %{mode: :search_results} = state) do
    SearchActions.handle_search_key(key.code, state)
  end

  def handle_event(%Event.Key{} = key, %{mode: :search_filter} = state) do
    SearchActions.handle_search_filter_key(key.code, state)
  end

  # A destructive action (list delete, queue/history single-item remove, or
  # queue/history clear) staged behind a yes/no prompt. "y" performs it; any other
  # key cancels (see Actions.handle_confirm_key/2).
  def handle_event(%Event.Key{} = key, %{mode: :confirm} = state) do
    Actions.handle_confirm_key(key.code, state)
  end

  def handle_event(%Event.Key{} = key, %{mode: :resume} = state) do
    PlaybackActions.handle_resume_key(key.code, state)
  end

  def handle_event(%Event.Key{} = key, %{mode: :list} = state) do
    Actions.handle_list_key(key.code, state)
  end

  def handle_event(%Event.Key{} = key, %{mode: :videos} = state) do
    Actions.handle_videos_key(key.code, state)
  end

  def handle_event(%Event.Key{} = key, %{mode: :channel_playlists} = state) do
    Actions.handle_channel_playlists_key(key.code, state)
  end

  def handle_event(%Event.Key{} = key, %{mode: :channel_playlists_filter} = state) do
    Actions.handle_channel_playlists_filter_key(key.code, state)
  end

  def handle_event(%Event.Key{} = key, %{mode: :input} = state) do
    Actions.handle_input_key(key, state)
  end

  # Incremental filter over the current browse list: the editor updates the term
  # live, while Enter/Esc close the field keeping it.
  def handle_event(%Event.Key{} = key, %{mode: :filter} = state) do
    Actions.handle_filter_key(key.code, state)
  end

  # Tracked channel/playlist/local tasks are terminated and invalidated on cancel.
  def handle_event(
        %Event.Key{code: "esc"},
        %{mode: :loading, local_request_ref: ref} = state
      )
      when not is_nil(ref) do
    {:noreply, Actions.cancel_local_entries(state)}
  end

  def handle_event(
        %Event.Key{code: "esc"},
        %{mode: :loading, playlist_request_ref: ref} = state
      )
      when not is_nil(ref) do
    {:noreply, Actions.cancel_playlist_videos(state)}
  end

  def handle_event(
        %Event.Key{code: "esc"},
        %{mode: :loading, channel_request_ref: ref} = state
      )
      when not is_nil(ref) do
    {:noreply, Actions.cancel_channel_videos(state)}
  end

  # Untracked add tasks keep running; mode guards drop late results.
  def handle_event(%Event.Key{code: "esc"}, %{mode: mode} = state)
      when mode in [:fetching, :loading] do
    {:noreply, %{state | mode: Actions.back_mode(state), status: {:info, "Canceled"}}}
  end

  def handle_event(%Event.Key{code: "esc"}, %{mode: :explore_loading} = state) do
    {:noreply, ExploreActions.cancel_explore(state)}
  end

  def handle_event(%Event.Key{code: "esc"}, %{mode: :search_loading} = state) do
    {:noreply, SearchActions.cancel_search(state)}
  end

  def handle_event(%Event.Key{code: "esc"}, %{mode: :channel_playlists_loading} = state) do
    {:noreply, Actions.cancel_channel_playlists(state)}
  end

  def handle_event(%Event.Key{}, %{mode: mode} = state)
      when mode in [
             :fetching,
             :loading,
             :channel_playlists_loading,
             :search_loading,
             :explore_loading,
             :playing
           ] do
    {:noreply, state}
  end

  # Bracketed paste arrives as one event, not a stream of key presses, so it
  # bypasses handle_input_key entirely. Insert it into the field when adding.
  def handle_event(%Event.Paste{content: content}, %{mode: :input} = state) do
    ExRatatui.text_input_insert_str(state.input, content)
    {:noreply, state}
  end

  def handle_event(%Event.Paste{content: content}, %{mode: :search_input} = state) do
    ExRatatui.text_input_insert_str(state.input, content)
    {:noreply, state}
  end

  def handle_event(_event, state) do
    {:noreply, state}
  end

  # --- add results ----------------------------------------------------------

  @impl true
  def handle_info({:add_result, _result} = msg, state), do: AddActions.handle_result(msg, state)

  def handle_info({:add_result, _result, _target} = msg, state),
    do: AddActions.handle_result(msg, state)

  # --- channel video listing ----------------------------------------------

  def handle_info(
        {:videos_result, ref, {:ok, videos}, name, url, tab},
        %{mode: :loading, channel_request_ref: ref} = state
      ) do
    {singular, plural} = if tab == :streams, do: {"stream", "streams"}, else: {"video", "videos"}

    status =
      if videos == [],
        do: {:info, "No #{plural} found for #{name}"},
        else: {:info, "#{Status.count_with_label(videos, singular, plural)} from #{name}"}

    {:noreply,
     %{
       state
       | mode: :videos,
         videos: videos,
         videos_return: :list,
         channel_request_ref: nil,
         channel_task_pid: nil,
         channel_name: name,
         channel_url: url,
         video_tab: tab,
         selected: 0,
         filter: "",
         status: status
     }}
  end

  # A tab fetch failed. When switching tabs on an already-open channel
  # (channel_url set), keep the current list on screen and just surface the
  # error, rather than dropping back to the subscription list. Otherwise (an
  # initial open) fall back to :list as before.
  def handle_info(
        {:videos_result, ref, {:error, reason}, _name, url, tab},
        %{mode: :loading, channel_request_ref: ref} = state
      ) do
    label = if tab == :streams, do: "streams", else: "videos"

    cond do
      state.loading_return == :channel_playlists ->
        {:noreply,
         %{
           state
           | mode: :channel_playlists,
             channel_request_ref: nil,
             channel_task_pid: nil,
             status: {:error, "Could not load #{label}: #{reason}"}
         }}

      is_binary(url) and state.videos != [] ->
        {:noreply,
         %{
           state
           | mode: :videos,
             channel_request_ref: nil,
             channel_task_pid: nil,
             status: {:error, "Could not load #{label}: #{reason}"}
         }}

      true ->
        {:noreply,
         %{
           state
           | mode: :list,
             channel_request_ref: nil,
             channel_task_pid: nil,
             status: {:error, "Could not load #{label}: #{reason}"}
         }}
    end
  end

  # Late video-list result after cancel.
  def handle_info({:videos_result, _ref, _result, _name, _url, _tab}, state),
    do: {:noreply, state}

  # --- channel playlist containers ----------------------------------------

  def handle_info(
        {:channel_playlists_result, ref, {:ok, playlists}, name, url},
        %{mode: :channel_playlists_loading, channel_playlists_request_ref: ref} = state
      ) do
    status =
      if playlists == [],
        do: {:info, "No playlists found for #{name}"},
        else: {:info, "#{Status.count_with_label(playlists, "playlist")} from #{name}"}

    {:noreply,
     %{
       state
       | mode: :channel_playlists,
         channel_playlists: playlists,
         channel_playlist_selected: 0,
         channel_playlist_filter: "",
         channel_playlist_channel_name: name,
         channel_playlist_channel_url: url,
         channel_playlists_request_ref: nil,
         channel_playlists_task_pid: nil,
         status: status
     }}
  end

  def handle_info(
        {:channel_playlists_result, ref, {:error, reason}, _name, _url},
        %{mode: :channel_playlists_loading, channel_playlists_request_ref: ref} = state
      ) do
    {:noreply,
     %{
       state
       | mode: state.channel_playlists_return,
         channel_playlists_request_ref: nil,
         channel_playlists_task_pid: nil,
         status: {:error, "Could not load playlists: #{reason}"}
     }}
  end

  def handle_info({:channel_playlists_result, _ref, _result, _name, _url}, state),
    do: {:noreply, state}

  def handle_info(
        {:channel_playlist_save_result, ref, {:ok, playlist}},
        %{channel_playlist_save_ref: ref} = state
      ) do
    {:noreply,
     %{
       state
       | playlists: Playlists.list_playlists(),
         channel_playlist_save_ref: nil,
         status: {:info, "Saved playlist: #{playlist.title}"}
     }}
  end

  def handle_info(
        {:channel_playlist_save_result, ref, {:error, reason}},
        %{channel_playlist_save_ref: ref} = state
      ) do
    {:noreply,
     %{
       state
       | channel_playlist_save_ref: nil,
         status: {:error, Status.add_error(reason, :playlist)}
     }}
  end

  def handle_info({:channel_playlist_save_result, _ref, _result}, state), do: {:noreply, state}

  # --- local entry listing -------------------------------------------------

  def handle_info(
        {:local_entries_result, ref, {:ok, entries}},
        %{mode: :loading, local_request_ref: ref, local_pending: pending} = state
      ) do
    {selected, filter} = local_result_selection(entries, pending)
    status = local_result_status(entries, pending)

    {:noreply,
     %{
       state
       | mode: :videos,
         videos: entries,
         videos_return: :list,
         channel_name: pending.name,
         channel_url: nil,
         video_tab: :videos,
         local_root: pending.root,
         local_root_name: pending.root_name,
         local_path: pending.path,
         local_stack: pending.stack,
         local_pending: nil,
         local_request_ref: nil,
         local_task_pid: nil,
         selected: selected,
         filter: filter,
         status: status
     }}
  end

  def handle_info(
        {:local_entries_result, ref, {:error, reason}},
        %{mode: :loading, local_request_ref: ref, local_pending: pending} = state
      ) do
    {:noreply,
     %{
       state
       | mode: state.loading_return,
         local_pending: nil,
         local_request_ref: nil,
         local_task_pid: nil,
         status: {:error, local_entries_error(pending, reason)}
     }}
  end

  # Late or stale local result after cancel or a newer request.
  def handle_info({:local_entries_result, _ref, _result}, state), do: {:noreply, state}

  # --- YouTube playlist listing -------------------------------------------

  def handle_info(
        {:playlist_videos_result, ref, {:ok, videos}, title},
        %{mode: :loading, playlist_request_ref: ref} = state
      ) do
    status =
      if videos == [],
        do: {:info, "No available videos in #{title}"},
        else: {:info, "#{Status.count_with_label(videos, "video")} from #{title}"}

    {:noreply,
     %{
       state
       | mode: :videos,
         videos: videos,
         videos_return: state.playlist_return,
         channel_name: title,
         channel_url: nil,
         video_tab: :videos,
         playlist_request_ref: nil,
         playlist_task_pid: nil,
         selected: 0,
         filter: "",
         status: status
     }}
  end

  def handle_info(
        {:playlist_videos_result, ref, {:error, reason}, _title},
        %{mode: :loading, playlist_request_ref: ref} = state
      ) do
    state =
      if state.playlist_return == :channel_playlists do
        %{
          state
          | channel_name: state.channel_playlist_channel_name,
            channel_url: state.channel_playlist_channel_url
        }
      else
        state
      end

    {:noreply,
     %{
       state
       | mode: state.playlist_return,
         playlist_request_ref: nil,
         playlist_task_pid: nil,
         status: {:error, "Could not load playlist: #{reason}"}
     }}
  end

  def handle_info({:playlist_videos_result, _ref, _result, _title}, state),
    do: {:noreply, state}

  # --- Search results ------------------------------------------------------

  def handle_info({:search_result, _ref, _result, _query} = msg, state),
    do: SearchActions.handle_result(msg, state)

  # --- Explore results -----------------------------------------------------

  def handle_info({:explore_result, _ref, _result} = msg, state),
    do: ExploreActions.handle_result(msg, state)

  # --- bookmarking a video --------------------------------------------------
  # Only the status line reflects progress/outcome; the originating list stays open.

  def handle_info({:bookmark_video_result, _result} = msg, state),
    do: AddActions.handle_bookmark_result(msg, state)

  # --- playback ------------------------------------------------------------

  def handle_info({:play_progress, _ref, _stage} = msg, state),
    do: PlaybackActions.handle_progress(msg, state)

  def handle_info({:play_result, _ref, _result} = msg, state),
    do: PlaybackActions.handle_result(msg, state)

  # The status-clear timer fired (see subscriptions/1). Clear the footer status,
  # but only if it still matches the status the timer was armed for — a newer
  # status set in the meantime must not be wiped. (The runtime also drops a stale
  # tick by token when the status changed, so this is belt-and-suspenders.)
  def handle_info({:clear_status, status}, %{status: status} = state) do
    {:noreply, %{state | status: nil}}
  end

  def handle_info({:clear_status, _status}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # --- subscriptions -------------------------------------------------------

  # A one-shot timer to clear a transient footer status after a few seconds, so a
  # stale "Added: …" / error doesn't linger indefinitely. The runtime reconciles
  # this after every transition (see ExRatatui.App), so we declare it purely as a
  # function of state: a set status arms the timer, a nil status returns none and
  # disarms it. The message carries the current status, which does double duty —
  # it lets handle_info avoid clobbering a newer status, and (because the runtime
  # diffs subscriptions by their fields) it forces a fresh timer whenever the
  # status changes, so each new message gets its own full window rather than
  # inheriting the previous one's already-fired timer.
  @status_clear_ms 5_000

  @impl true
  def subscriptions(%{status: nil}), do: []

  def subscriptions(%{status: status}) do
    [ExRatatui.Subscription.once(:status_clear, @status_clear_ms, {:clear_status, status})]
  end

  # --- rendering -----------------------------------------------------------

  @impl true
  def render(state, frame), do: View.render(state, frame)

  # --- handle_info helpers -------------------------------------------------

  defp local_entries_status([], name), do: "No media files or folders in #{name}"

  defp local_entries_status(entries, name) do
    directories = Enum.count(entries, &(&1.kind == :directory))
    files = length(entries) - directories

    counts =
      [{directories, "folder"}, {files, "file"}]
      |> Enum.reject(fn {count, _label} -> count == 0 end)
      |> Enum.map_join(", ", fn {count, label} -> Status.count_with_number(count, label) end)

    "#{counts} in #{name}"
  end

  defp local_result_status(entries, pending) do
    status = local_entries_status(entries, pending.name)
    {:info, if(Map.get(pending, :refresh, false), do: "Refreshed: #{status}", else: status)}
  end

  defp local_result_selection(entries, pending) do
    if Map.get(pending, :refresh, false) do
      filter = Map.get(pending, :filter, "")
      visible = Filter.narrow(entries, [:title], filter)
      selected_id = Map.get(pending, :selected_id)

      selected =
        Enum.find_index(visible, &(Map.get(&1, :id) == selected_id)) ||
          min(Map.get(pending, :selected, 0), max(length(visible) - 1, 0))

      {selected, filter}
    else
      {0, ""}
    end
  end

  defp local_entries_error(pending, reason) do
    if pending.path == pending.root do
      ~s(Local directory "#{pending.root_name}" is offline or unavailable: #{reason})
    else
      ~s(Local folder "#{pending.name}" is unavailable: #{reason})
    end
  end
end
