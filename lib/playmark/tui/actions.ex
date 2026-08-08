defmodule Playmark.TUI.Actions do
  @moduledoc """
  State transitions for `Playmark.TUI`: the per-mode key handlers, list
  navigation, and the task spawners that shell out or hit the network.

  Every function takes the current UI state and returns either a new state map
  (for the key-handler helpers invoked internally) or the `{:noreply, state}` /
  `{:stop, state}` tuple the runtime expects (for the top-level `handle_*_key`
  entry points). Anything that could block — adding, listing videos, playback —
  is run in a spawned task that reports back to the runtime process, so the UI
  never stalls. Tracked requests use references; remaining late add results are
  dropped by mode guards in `Playmark.TUI.handle_info/2`.
  """

  alias ExRatatui.Event

  alias Playmark.TUI.{Filter, HelpActions, Impl, Nav}

  # Called directly, not through `Impl`: the delete paths below, the queue, URL
  # canonicalization, and `Playback`'s config reads (see `Impl`'s moduledoc on
  # why those must not go through the seam).
  alias Playmark.{Bookmarks, Locals, Playback, Playlists, Queue, Subscriptions, YouTube}

  @minimum_resume_ms 10_000
  @completion_window_ms 30_000

  # --- list mode -----------------------------------------------------------

  def handle_list_key("q", state), do: {:stop, state}
  def handle_list_key("j", state), do: {:noreply, move(state, 1)}
  def handle_list_key("down", state), do: {:noreply, move(state, 1)}
  def handle_list_key("k", state), do: {:noreply, move(state, -1)}
  def handle_list_key("up", state), do: {:noreply, move(state, -1)}
  def handle_list_key("g", state), do: {:noreply, move(state, :top)}
  def handle_list_key("home", state), do: {:noreply, move(state, :top)}
  def handle_list_key("G", state), do: {:noreply, move(state, :bottom)}
  def handle_list_key("end", state), do: {:noreply, move(state, :bottom)}
  def handle_list_key("page_up", state), do: {:noreply, move(state, -Nav.page_step())}
  def handle_list_key("page_down", state), do: {:noreply, move(state, Nav.page_step())}
  def handle_list_key("tab", state), do: {:noreply, toggle_view(state)}
  def handle_list_key("/", state), do: {:noreply, open_filter(state)}
  def handle_list_key("a", state), do: {:noreply, start_input(state)}
  def handle_list_key("d", state), do: {:noreply, confirm_delete_selected(state)}
  def handle_list_key("enter", state), do: {:noreply, activate_selected(state)}
  # "e" appends the selected bookmark to the playback queue. Container rows are
  # opened first and their individual videos are queued from :videos mode.
  def handle_list_key("e", %{view: :bookmarks} = state),
    do: {:noreply, enqueue_selected(state, :tail)}

  def handle_list_key("e", state), do: {:noreply, state}
  # "n" plays the selected bookmark next — inserted right after the queue head.
  def handle_list_key("n", %{view: :bookmarks} = state),
    do: {:noreply, enqueue_selected(state, :next)}

  def handle_list_key("n", state), do: {:noreply, state}
  # Esc clears an active filter (there's otherwise no Esc binding in :list); with
  # no filter it's a no-op. See open_filter/1 and handle_filter_key/2.
  def handle_list_key("esc", %{filter: ""} = state), do: {:noreply, state}
  def handle_list_key("esc", state), do: {:noreply, %{state | filter: "", selected: 0}}
  def handle_list_key(_code, state), do: {:noreply, state}

  # Tab cycles the four top-level views. Clear any video list / channel label
  # left over from an opened source so nothing stale
  # leaks into the new view.
  defp toggle_view(state) do
    next =
      case state.view do
        :bookmarks -> :subscriptions
        :subscriptions -> :playlists
        :playlists -> :locals
        :locals -> :bookmarks
      end

    state
    |> clear_local_browser()
    |> Map.merge(%{
      view: next,
      videos: [],
      channel_name: nil,
      selected: 0,
      status: nil,
      filter: ""
    })
  end

  defp start_input(state) do
    # Clear any leftover text from a previous add before showing the field.
    ExRatatui.text_input_set_value(state.input, "")
    %{state | mode: :input, status: nil}
  end

  # Enter on the current list: play a bookmark or open a saved source.
  defp activate_selected(%{view: :bookmarks} = state), do: play_selected(state)
  defp activate_selected(%{view: :subscriptions} = state), do: load_videos(state)
  defp activate_selected(%{view: :playlists} = state), do: load_playlist_videos(state)
  defp activate_selected(%{view: :locals} = state), do: load_files(state)

  # A delete is destructive and a single keystroke, so it's staged behind a
  # confirmation rather than done immediately. We snapshot the item and a prompt
  # into `confirm`, flip to :confirm mode, and remember the mode to return to on
  # cancel. The actual delete runs from handle_confirm_key/2 on "y". A no-op when
  # nothing is selected (e.g. an empty list).
  defp confirm_delete_selected(state) do
    case selected_item(state) do
      nil ->
        state

      item ->
        %{
          state
          | mode: :confirm,
            confirm_return: :list,
            confirm: %{action: :delete_selected, prompt: delete_prompt(state, item)},
            status: nil
        }
    end
  end

  # The confirmation prompt for deleting the selected item, worded per view.
  defp delete_prompt(%{view: :bookmarks}, item), do: "Delete bookmark \"#{item.title}\"?"
  defp delete_prompt(%{view: :subscriptions}, item), do: "Unsubscribe from \"#{item.name}\"?"
  defp delete_prompt(%{view: :playlists}, item), do: "Remove playlist \"#{item.title}\"?"
  defp delete_prompt(%{view: :locals}, item), do: "Remove local directory \"#{item.name}\"?"

  # --- confirmation mode ---------------------------------------------------

  # "y" performs the staged action; any other key (including "n"/Esc) cancels.
  # The action name in `confirm` decides what runs, then we drop back to the mode
  # it was invoked from. Kept as a small dispatch so new confirmable actions only
  # add a perform clause plus their confirm_* entry point.
  def handle_confirm_key("y", %{confirm: %{action: action}} = state) do
    {:noreply, perform_confirmed(action, state)}
  end

  def handle_confirm_key(_code, state), do: {:noreply, cancel_confirm(state)}

  # A saved checkpoint is a three-way choice rather than a destructive yes/no
  # confirmation: resume, deliberately start over, or cancel without recording a
  # new history play.
  def handle_resume_key("y", %{resume: pending} = state) when is_map(pending) do
    {:noreply, launch_pending_resume(state, pending.position_ms)}
  end

  def handle_resume_key("n", %{resume: pending} = state) when is_map(pending) do
    safe_history(fn -> Impl.history().clear_checkpoint(pending.playable.url) end)
    {:noreply, launch_pending_resume(state, nil)}
  end

  def handle_resume_key("esc", %{resume: pending} = state) when is_map(pending) do
    {:noreply,
     %{
       state
       | mode: pending.display_mode,
         resume: nil,
         playing: nil,
         status: {:info, "Canceled"}
     }}
  end

  def handle_resume_key(_code, state), do: {:noreply, state}

  defp cancel_confirm(state) do
    %{state | mode: state.confirm_return, confirm: nil, status: {:info, "Canceled"}}
  end

  defp perform_confirmed(:delete_selected, state) do
    %{delete_selected(state) | mode: :list, confirm: nil}
  end

  defp perform_confirmed(:clear_queue, state) do
    %{clear_queue(state) | mode: :queue_manage, confirm: nil}
  end

  defp perform_confirmed(:clear_history, state) do
    %{clear_history(state) | mode: :history, confirm: nil}
  end

  defp perform_confirmed(:remove_queued, state) do
    %{remove_queued(state) | mode: :queue_manage, confirm: nil}
  end

  defp perform_confirmed(:remove_history, state) do
    %{remove_history(state) | mode: :history, confirm: nil}
  end

  defp delete_selected(state) do
    case selected_item(state) do
      nil ->
        state

      item ->
        case state.view do
          :bookmarks ->
            {:ok, _} = Bookmarks.delete_bookmark(item)
            bookmarks = Bookmarks.list_bookmarks()

            %{
              state
              | bookmarks: bookmarks,
                selected: Nav.clamp_index(state.selected, bookmarks),
                status: {:info, "Deleted"}
            }

          :subscriptions ->
            {:ok, _} = Subscriptions.delete_subscription(item)
            subscriptions = Subscriptions.list_subscriptions()

            %{
              state
              | subscriptions: subscriptions,
                selected: Nav.clamp_index(state.selected, subscriptions),
                status: {:info, "Unsubscribed"}
            }

          :playlists ->
            {:ok, _} = Playlists.delete_playlist(item)
            playlists = Playlists.list_playlists()

            %{
              state
              | playlists: playlists,
                selected: Nav.clamp_index(state.selected, playlists),
                status: {:info, "Removed"}
            }

          :locals ->
            {:ok, _} = Locals.delete_local(item)
            locals = Locals.list_locals()

            %{
              state
              | locals: locals,
                selected: Nav.clamp_index(state.selected, locals),
                status: {:info, "Removed"}
            }
        end
    end
  end

  # --- videos mode ---------------------------------------------------------

  def handle_videos_key("q", state), do: {:stop, state}
  def handle_videos_key("j", state), do: {:noreply, move(state, 1)}
  def handle_videos_key("down", state), do: {:noreply, move(state, 1)}
  def handle_videos_key("k", state), do: {:noreply, move(state, -1)}
  def handle_videos_key("up", state), do: {:noreply, move(state, -1)}
  def handle_videos_key("g", state), do: {:noreply, move(state, :top)}
  def handle_videos_key("home", state), do: {:noreply, move(state, :top)}
  def handle_videos_key("G", state), do: {:noreply, move(state, :bottom)}
  def handle_videos_key("end", state), do: {:noreply, move(state, :bottom)}
  def handle_videos_key("page_up", state), do: {:noreply, move(state, -Nav.page_step())}
  def handle_videos_key("page_down", state), do: {:noreply, move(state, Nav.page_step())}

  def handle_videos_key("enter", %{view: :locals} = state),
    do: {:noreply, activate_local_entry(state)}

  def handle_videos_key("enter", state), do: {:noreply, play_selected(state)}
  # Bookmarking goes through oEmbed, which only knows YouTube URLs — a local
  # file has none, so it's a no-op here with an explanatory status.
  def handle_videos_key("b", %{view: :locals} = state) do
    {:noreply, %{state | status: {:info, "Bookmarking is for YouTube videos only"}}}
  end

  def handle_videos_key("b", state), do: {:noreply, bookmark_selected_video(state)}

  # "e" appends the selected channel/playlist video or local file to the
  # playback queue, carrying its own local? flag so the play path is right later.
  def handle_videos_key("e", state), do: {:noreply, enqueue_selected(state, :tail)}
  # "n" plays the selected video next — inserted right after the queue head.
  def handle_videos_key("n", state), do: {:noreply, enqueue_selected(state, :next)}

  # Direct channel listings expose `s`/`v` for playable tabs and `p` for the
  # non-playable playlist-container level. These are no-ops for videos opened
  # from a saved/channel playlist or a local directory (`channel_url` is nil).
  def handle_videos_key("s", state), do: {:noreply, switch_tab(state, :streams)}
  def handle_videos_key("v", state), do: {:noreply, switch_tab(state, :videos)}
  def handle_videos_key("p", state), do: {:noreply, open_channel_playlists(state)}

  # "/" opens the incremental filter over the current video list (see open_filter/1).
  def handle_videos_key("/", state), do: {:noreply, open_filter(state)}

  def handle_videos_key(
        "r",
        %{view: :locals, local_path: path, local_root: root} = state
      )
      when is_binary(path) and is_binary(root),
      do: {:noreply, refresh_local_entries(state)}

  # Esc first clears an active filter (staying in :videos); with no filter it goes
  # back to the list we came from. The view is unchanged — a video list is only
  # ever opened from Subscriptions, Playlists, or Locals — so keep it, clearing the
  # results.
  def handle_videos_key("esc", %{filter: filter} = state) when filter != "" do
    {:noreply, %{state | filter: "", selected: 0}}
  end

  def handle_videos_key("esc", %{videos_return: :channel_playlists} = state) do
    {:noreply, restore_channel_playlists(state)}
  end

  def handle_videos_key("esc", %{view: :locals, local_stack: [parent | rest]} = state) do
    {:noreply,
     %{
       state
       | videos: parent.entries,
         channel_name: parent.name,
         local_path: parent.path,
         local_stack: rest,
         selected: parent.selected,
         filter: parent.filter,
         status: nil
     }}
  end

  def handle_videos_key("esc", %{view: :locals} = state) do
    {:noreply,
     state
     |> clear_local_browser()
     |> Map.merge(%{
       mode: :list,
       videos: [],
       channel_name: nil,
       channel_url: nil,
       video_tab: :videos,
       selected: 0,
       status: nil,
       filter: ""
     })}
  end

  def handle_videos_key("esc", state) do
    {:noreply,
     %{
       state
       | mode: :list,
         videos: [],
         channel_name: nil,
         channel_url: nil,
         video_tab: :videos,
         selected: 0,
         status: nil,
         filter: ""
     }}
  end

  def handle_videos_key(_code, state), do: {:noreply, state}

  # --- channel Playlists tab ----------------------------------------------

  def handle_channel_playlists_key("q", state), do: {:stop, state}
  def handle_channel_playlists_key("j", state), do: {:noreply, move_channel_playlist(state, 1)}

  def handle_channel_playlists_key("down", state),
    do: {:noreply, move_channel_playlist(state, 1)}

  def handle_channel_playlists_key("k", state),
    do: {:noreply, move_channel_playlist(state, -1)}

  def handle_channel_playlists_key("up", state),
    do: {:noreply, move_channel_playlist(state, -1)}

  def handle_channel_playlists_key("g", state),
    do: {:noreply, move_channel_playlist(state, :top)}

  def handle_channel_playlists_key("home", state),
    do: {:noreply, move_channel_playlist(state, :top)}

  def handle_channel_playlists_key("G", state),
    do: {:noreply, move_channel_playlist(state, :bottom)}

  def handle_channel_playlists_key("end", state),
    do: {:noreply, move_channel_playlist(state, :bottom)}

  def handle_channel_playlists_key("page_up", state),
    do: {:noreply, move_channel_playlist(state, -Nav.page_step())}

  def handle_channel_playlists_key("page_down", state),
    do: {:noreply, move_channel_playlist(state, Nav.page_step())}

  def handle_channel_playlists_key("enter", state),
    do: {:noreply, load_channel_playlist_videos(state)}

  def handle_channel_playlists_key("p", state),
    do: {:noreply, save_channel_playlist(state)}

  def handle_channel_playlists_key("s", state),
    do: {:noreply, switch_from_channel_playlists(state, :streams)}

  def handle_channel_playlists_key("v", state),
    do: {:noreply, switch_from_channel_playlists(state, :videos)}

  def handle_channel_playlists_key("/", state) do
    ExRatatui.text_input_set_value(state.input, state.channel_playlist_filter)
    {:noreply, %{state | mode: :channel_playlists_filter}}
  end

  def handle_channel_playlists_key("esc", %{channel_playlist_filter: filter} = state)
      when filter != "" do
    {:noreply, %{state | channel_playlist_filter: "", channel_playlist_selected: 0}}
  end

  def handle_channel_playlists_key("esc", state),
    do: {:noreply, close_channel_playlists(state)}

  def handle_channel_playlists_key(_code, state), do: {:noreply, state}

  def handle_channel_playlists_filter_key("enter", state),
    do: {:noreply, %{state | mode: :channel_playlists}}

  def handle_channel_playlists_filter_key("esc", state),
    do: {:noreply, %{state | mode: :channel_playlists}}

  def handle_channel_playlists_filter_key(code, state) do
    ExRatatui.text_input_handle_key(state.input, code)
    filter = ExRatatui.text_input_get_value(state.input)
    {:noreply, reclamp_channel_playlists(%{state | channel_playlist_filter: filter})}
  end

  defp move_channel_playlist(state, target) when target in [:top, :bottom] do
    case Nav.jump_index(Filter.visible_channel_playlists(state), target) do
      nil -> state
      index -> %{state | channel_playlist_selected: index}
    end
  end

  defp move_channel_playlist(state, delta) do
    playlists = Filter.visible_channel_playlists(state)

    case playlists do
      [] ->
        state

      _ ->
        %{
          state
          | channel_playlist_selected:
              Nav.clamp(state.channel_playlist_selected + delta, 0, length(playlists) - 1)
        }
    end
  end

  defp reclamp_channel_playlists(state) do
    playlists = Filter.visible_channel_playlists(state)

    %{
      state
      | channel_playlist_selected:
          Nav.clamp(state.channel_playlist_selected, 0, max(length(playlists) - 1, 0))
    }
  end

  defp selected_channel_playlist(state) do
    state
    |> Filter.visible_channel_playlists()
    |> Enum.at(state.channel_playlist_selected)
  end

  # --- filter mode ---------------------------------------------------------

  # Open the incremental filter field over the current browse list, remembering
  # the base mode to restore when it closes (:list or :videos). The current
  # `filter` term is kept, so reopening the field prefills it for editing.
  defp open_filter(state) do
    ExRatatui.text_input_set_value(state.input, state.filter)
    %{state | mode: :filter, filter_return: state.mode}
  end

  # Live filter over the current list: the shared editor handles insertion,
  # deletion, and cursor movement. Enter/Esc close the field keeping the term.
  # After every edit the selection is reclamped into the newly-narrowed list.
  def handle_filter_key("enter", state), do: {:noreply, %{state | mode: state.filter_return}}
  def handle_filter_key("esc", state), do: {:noreply, %{state | mode: state.filter_return}}

  def handle_filter_key(code, state) do
    ExRatatui.text_input_handle_key(state.input, code)
    filter = ExRatatui.text_input_get_value(state.input)
    {:noreply, reclamp_filtered(%{state | filter: filter})}
  end

  # Keep `selected` within the filtered list after the term changes.
  defp reclamp_filtered(state) do
    %{state | selected: Nav.clamp(state.selected, 0, max(length(current_list(state)) - 1, 0))}
  end

  # --- input mode ----------------------------------------------------------

  def handle_input_key(%Event.Key{code: "esc"}, state) do
    {:noreply, %{state | mode: :list, status: nil}}
  end

  def handle_input_key(%Event.Key{code: "enter"}, state) do
    value = state.input |> ExRatatui.text_input_get_value() |> String.trim()

    if value == "" do
      message =
        if state.view == :locals, do: "Enter a directory path first", else: "Enter a URL first"

      {:noreply, %{state | status: {:error, message}}}
    else
      {:noreply, start_add(value, state)}
    end
  end

  def handle_input_key(%Event.Key{code: code}, state) do
    # Forward the keystroke to the TextInput's editor (insert, backspace,
    # cursor movement, etc.), then re-render with its updated state.
    ExRatatui.text_input_handle_key(state.input, code)
    {:noreply, state}
  end

  # --- navigation ----------------------------------------------------------

  defp move(state, target) when target in [:top, :bottom] do
    case Nav.jump_index(current_list(state), target) do
      nil -> state
      index -> %{state | selected: index}
    end
  end

  defp move(state, delta) do
    list = current_list(state)

    case list do
      [] -> state
      _ -> %{state | selected: Nav.clamp(state.selected + delta, 0, length(list) - 1)}
    end
  end

  # The list the selection currently points into, given view + mode, narrowed by
  # the active filter term. Delegates to `Playmark.TUI.Filter.visible/1` — the
  # single place the view/mode→list mapping lives, shared with the view so what's
  # navigated and what's rendered can never diverge. The queue-manage modal
  # navigates its own list via `queue_selected` (see handle_queue_key/2), so it
  # isn't represented here.
  defp current_list(state), do: Filter.visible(state)

  defp selected_item(state) do
    Enum.at(current_list(state), state.selected)
  end

  # --- Explore -------------------------------------------------------------

  def open_explore(state) do
    parent = self()
    request_ref = make_ref()
    impl = Impl.explore()

    {:ok, task_pid} =
      Task.start(fn ->
        result =
          try do
            impl.homepage()
          rescue
            error -> {:error, Exception.message(error)}
          end

        send(parent, {:explore_result, request_ref, result})
      end)

    %{
      state
      | mode: :explore_loading,
        explore_return: state.mode,
        explore_videos: [],
        explore_selected: 0,
        explore_request_ref: request_ref,
        explore_task_pid: task_pid,
        status: {:info, "Loading YouTube recommendations… (Esc to cancel)"}
    }
  end

  def cancel_explore(state) do
    if is_pid(state.explore_task_pid) and Process.alive?(state.explore_task_pid) do
      Process.exit(state.explore_task_pid, :kill)
    end

    %{
      state
      | mode: state.explore_return,
        explore_request_ref: nil,
        explore_task_pid: nil,
        status: {:info, "Canceled"}
    }
  end

  def handle_explore_key("q", state), do: {:stop, state}
  def handle_explore_key("j", state), do: {:noreply, move_explore(state, 1)}
  def handle_explore_key("down", state), do: {:noreply, move_explore(state, 1)}
  def handle_explore_key("k", state), do: {:noreply, move_explore(state, -1)}
  def handle_explore_key("up", state), do: {:noreply, move_explore(state, -1)}
  def handle_explore_key("g", state), do: {:noreply, move_explore(state, :top)}
  def handle_explore_key("home", state), do: {:noreply, move_explore(state, :top)}
  def handle_explore_key("G", state), do: {:noreply, move_explore(state, :bottom)}
  def handle_explore_key("end", state), do: {:noreply, move_explore(state, :bottom)}
  def handle_explore_key("page_up", state), do: {:noreply, move_explore(state, -Nav.page_step())}
  def handle_explore_key("page_down", state), do: {:noreply, move_explore(state, Nav.page_step())}
  def handle_explore_key("enter", state), do: {:noreply, play_explore_selected(state)}
  def handle_explore_key("b", state), do: {:noreply, bookmark_explore_selected(state)}
  def handle_explore_key("e", state), do: {:noreply, enqueue_explore_selected(state, :tail)}
  def handle_explore_key("n", state), do: {:noreply, enqueue_explore_selected(state, :next)}

  def handle_explore_key("esc", state) do
    {:noreply, %{state | mode: state.explore_return, status: nil}}
  end

  def handle_explore_key(_code, state), do: {:noreply, state}

  defp move_explore(%{explore_videos: []} = state, _delta), do: state

  defp move_explore(state, target) when target in [:top, :bottom] do
    %{state | explore_selected: Nav.jump_index(state.explore_videos, target)}
  end

  defp move_explore(state, delta) do
    selected = Nav.clamp(state.explore_selected + delta, 0, length(state.explore_videos) - 1)
    %{state | explore_selected: selected}
  end

  defp selected_explore_video(state) do
    Enum.at(state.explore_videos, state.explore_selected)
  end

  defp play_explore_selected(state) do
    case selected_explore_video(state) do
      nil -> state
      video -> start_play(Nav.playable_video(video), :explore, state)
    end
  end

  defp bookmark_explore_selected(state) do
    case selected_explore_video(state) do
      nil -> state
      video -> bookmark_video(video, state)
    end
  end

  defp enqueue_explore_selected(state, target) do
    case selected_explore_video(state) do
      nil -> state
      video -> do_enqueue(state, Nav.playable_video(video), video.title, target)
    end
  end

  # --- Search --------------------------------------------------------------

  def open_search(state) do
    ExRatatui.text_input_set_value(state.input, "")

    %{
      state
      | mode: :search_input,
        search_return: state.mode,
        search_videos: [],
        search_selected: 0,
        search_query: "",
        search_filter: "",
        search_request_ref: nil,
        search_task_pid: nil,
        status: nil
    }
  end

  def handle_search_input_key(%Event.Key{code: "esc"}, state) do
    {:noreply, close_search(state)}
  end

  def handle_search_input_key(%Event.Key{code: "enter"}, state) do
    query = state.input |> ExRatatui.text_input_get_value() |> String.trim()

    if query == "" do
      {:noreply, %{state | status: {:error, "Enter a query first"}}}
    else
      {:noreply, start_search(query, state)}
    end
  end

  def handle_search_input_key(%Event.Key{code: code}, state) do
    ExRatatui.text_input_handle_key(state.input, code)
    {:noreply, state}
  end

  defp start_search(query, state) do
    parent = self()
    request_ref = make_ref()
    impl = Impl.search()

    {:ok, task_pid} =
      Task.start(fn ->
        result =
          try do
            impl.search(query)
          rescue
            error -> {:error, Exception.message(error)}
          end

        send(parent, {:search_result, request_ref, result, query})
      end)

    %{
      state
      | mode: :search_loading,
        search_query: query,
        search_request_ref: request_ref,
        search_task_pid: task_pid,
        status: {:info, "Searching #{query}… (Esc to cancel)"}
    }
  end

  def cancel_search(state) do
    if is_pid(state.search_task_pid) and Process.alive?(state.search_task_pid) do
      Process.exit(state.search_task_pid, :kill)
    end

    close_search(%{state | search_request_ref: nil, search_task_pid: nil})
  end

  def handle_search_key("q", state), do: {:stop, state}
  def handle_search_key("j", state), do: {:noreply, move_search(state, 1)}
  def handle_search_key("down", state), do: {:noreply, move_search(state, 1)}
  def handle_search_key("k", state), do: {:noreply, move_search(state, -1)}
  def handle_search_key("up", state), do: {:noreply, move_search(state, -1)}
  def handle_search_key("g", state), do: {:noreply, move_search(state, :top)}
  def handle_search_key("home", state), do: {:noreply, move_search(state, :top)}
  def handle_search_key("G", state), do: {:noreply, move_search(state, :bottom)}
  def handle_search_key("end", state), do: {:noreply, move_search(state, :bottom)}
  def handle_search_key("page_up", state), do: {:noreply, move_search(state, -Nav.page_step())}
  def handle_search_key("page_down", state), do: {:noreply, move_search(state, Nav.page_step())}
  def handle_search_key("enter", state), do: {:noreply, play_search_selected(state)}
  def handle_search_key("b", state), do: {:noreply, bookmark_search_selected(state)}
  def handle_search_key("e", state), do: {:noreply, enqueue_search_selected(state, :tail)}
  def handle_search_key("n", state), do: {:noreply, enqueue_search_selected(state, :next)}

  def handle_search_key("/", state) do
    ExRatatui.text_input_set_value(state.input, state.search_filter)
    {:noreply, %{state | mode: :search_filter}}
  end

  def handle_search_key("S", state) do
    ExRatatui.text_input_set_value(state.input, "")

    {:noreply,
     %{
       state
       | mode: :search_input,
         search_videos: [],
         search_selected: 0,
         search_query: "",
         search_filter: "",
         status: nil
     }}
  end

  def handle_search_key("esc", %{search_filter: filter} = state) when filter != "" do
    {:noreply, %{state | search_filter: "", search_selected: 0}}
  end

  def handle_search_key("esc", state), do: {:noreply, close_search(state)}
  def handle_search_key(_code, state), do: {:noreply, state}

  def handle_search_filter_key("enter", state),
    do: {:noreply, %{state | mode: :search_results}}

  def handle_search_filter_key("esc", state),
    do: {:noreply, %{state | mode: :search_results}}

  def handle_search_filter_key(code, state) do
    ExRatatui.text_input_handle_key(state.input, code)
    filter = ExRatatui.text_input_get_value(state.input)
    {:noreply, reclamp_search(%{state | search_filter: filter})}
  end

  defp move_search(state, target) when target in [:top, :bottom] do
    case Nav.jump_index(Filter.visible_search(state), target) do
      nil -> state
      index -> %{state | search_selected: index}
    end
  end

  defp move_search(state, delta) do
    case Filter.visible_search(state) do
      [] ->
        state

      videos ->
        %{
          state
          | search_selected: Nav.clamp(state.search_selected + delta, 0, length(videos) - 1)
        }
    end
  end

  defp reclamp_search(state) do
    visible = Filter.visible_search(state)
    %{state | search_selected: Nav.clamp(state.search_selected, 0, max(length(visible) - 1, 0))}
  end

  defp selected_search_video(state),
    do: Enum.at(Filter.visible_search(state), state.search_selected)

  defp play_search_selected(state) do
    case selected_search_video(state) do
      nil -> state
      video -> start_play(Nav.playable_video(video), :search, state)
    end
  end

  defp bookmark_search_selected(state) do
    case selected_search_video(state) do
      nil -> state
      video -> bookmark_video(video, state)
    end
  end

  defp enqueue_search_selected(state, target) do
    case selected_search_video(state) do
      nil -> state
      video -> do_enqueue(state, Nav.playable_video(video), video.title, target)
    end
  end

  defp close_search(state) do
    %{
      state
      | mode: state.search_return,
        search_request_ref: nil,
        search_task_pid: nil,
        status: nil
    }
  end

  # --- queue ---------------------------------------------------------------

  # Append the selected item to the playback queue, carrying the local? flag the
  # play path forks on (the active view decides it here, at enqueue time). A
  # no-op where there is no selected playable row.
  defp enqueue_selected(state, target) do
    case selected_item(state) do
      nil ->
        state

      %{kind: :directory} when state.view == :locals ->
        %{state | status: {:info, "Only media files can be queued"}}

      item ->
        attrs = %{
          title: item.title,
          url: item.url,
          local: state.view == :locals,
          author: Nav.item_author(item)
        }

        do_enqueue(state, attrs, item.title, target)
    end
  end

  # The single funnel every enqueue routes through: `:tail` appends to the end of
  # the queue, `:next` inserts the item just after the current head so it plays
  # next. Both refresh the in-memory queue and set a status. A no-op caller (nil
  # selection) is handled before this is reached.
  defp do_enqueue(state, attrs, title, target) do
    result =
      case target do
        :next -> Queue.enqueue_next(attrs)
        _tail -> Queue.enqueue(attrs)
      end

    label = if target == :next, do: "Playing next", else: "Queued"

    case result do
      {:ok, _} ->
        %{state | queue: Queue.list_items(), status: {:info, "#{label}: #{title}"}}

      {:error, _changeset} ->
        %{state | status: {:error, "Couldn't queue that item"}}
    end
  end

  # Open the queue-manage modal, remembering the mode to restore on Esc. The
  # modal is reachable from any browse mode or over the running player; the
  # running player is untouched; changes affect the persisted queue.
  def open_queue(state) do
    %{
      state
      | mode: :queue_manage,
        queue_return: state.mode,
        queue: Queue.list_items(),
        queue_selected: Nav.clamp(state.queue_selected, 0, max(length(state.queue) - 1, 0))
    }
  end

  def handle_queue_key("q", state), do: {:stop, state}
  def handle_queue_key("j", state), do: {:noreply, move_queue(state, 1)}
  def handle_queue_key("down", state), do: {:noreply, move_queue(state, 1)}
  def handle_queue_key("k", state), do: {:noreply, move_queue(state, -1)}
  def handle_queue_key("up", state), do: {:noreply, move_queue(state, -1)}
  def handle_queue_key("g", state), do: {:noreply, move_queue(state, :top)}
  def handle_queue_key("home", state), do: {:noreply, move_queue(state, :top)}
  def handle_queue_key("G", state), do: {:noreply, move_queue(state, :bottom)}
  def handle_queue_key("end", state), do: {:noreply, move_queue(state, :bottom)}
  def handle_queue_key("page_up", state), do: {:noreply, move_queue(state, -Nav.page_step())}
  def handle_queue_key("page_down", state), do: {:noreply, move_queue(state, Nav.page_step())}
  def handle_queue_key("d", state), do: {:noreply, confirm_remove_queued(state)}
  def handle_queue_key("[", state), do: {:noreply, reorder_queued(state, :up)}
  def handle_queue_key("]", state), do: {:noreply, reorder_queued(state, :down)}
  def handle_queue_key("c", state), do: {:noreply, confirm_clear_queue(state)}
  def handle_queue_key("enter", state), do: {:noreply, start_queue(state)}

  # Esc closes the modal, restoring the mode it was opened from.
  def handle_queue_key("esc", state) do
    {:noreply, %{state | mode: state.queue_return, status: nil}}
  end

  def handle_queue_key(_code, state), do: {:noreply, state}

  defp move_queue(state, target) when target in [:top, :bottom] do
    case Nav.jump_index(state.queue, target) do
      nil -> state
      index -> %{state | queue_selected: index}
    end
  end

  defp move_queue(state, delta) do
    case state.queue do
      [] ->
        state

      queue ->
        %{state | queue_selected: Nav.clamp(state.queue_selected + delta, 0, length(queue) - 1)}
    end
  end

  defp selected_queue_item(state), do: Enum.at(state.queue, state.queue_selected)

  # A single-item remove is destructive and a single keystroke, so it's staged
  # behind a confirmation like a list delete. The selection index is preserved
  # through :confirm mode, so remove_queued/1 (run from handle_confirm_key/2 on "y")
  # resolves the same item. A no-op when nothing is selected (empty queue).
  defp confirm_remove_queued(state) do
    case selected_queue_item(state) do
      nil ->
        state

      item ->
        %{
          state
          | mode: :confirm,
            confirm_return: :queue_manage,
            confirm: %{action: :remove_queued, prompt: "Remove \"#{item.title}\" from the queue?"},
            status: nil
        }
    end
  end

  defp remove_queued(state) do
    case selected_queue_item(state) do
      nil ->
        state

      item ->
        {:ok, _} = Queue.remove(item)
        queue = Queue.list_items()

        %{
          state
          | queue: queue,
            queue_selected: Nav.clamp(state.queue_selected, 0, max(length(queue) - 1, 0)),
            status: {:info, "Removed from queue"}
        }
    end
  end

  # Reorder keeps the cursor on the moved item so repeated presses walk it along.
  defp reorder_queued(state, direction) do
    case selected_queue_item(state) do
      nil ->
        state

      item ->
        case direction do
          :up -> Queue.move_up(item)
          :down -> Queue.move_down(item)
        end

        queue = Queue.list_items()
        index = Enum.find_index(queue, &(&1.id == item.id)) || state.queue_selected
        %{state | queue: queue, queue_selected: index}
    end
  end

  # Clearing wipes the whole queue in one keystroke, so it's staged behind a
  # confirmation like a list delete. A no-op (with a hint) on an empty queue so
  # the prompt never appears for nothing. The clear itself runs from
  # handle_confirm_key/2 on "y"; Esc/other keys return to the modal.
  defp confirm_clear_queue(%{queue: []} = state) do
    %{state | status: {:info, "Queue is already empty"}}
  end

  defp confirm_clear_queue(state) do
    %{
      state
      | mode: :confirm,
        confirm_return: :queue_manage,
        confirm: %{
          action: :clear_queue,
          prompt: "Clear all #{count_with_label(state.queue, "queued item")}?"
        },
        status: nil
    }
  end

  defp clear_queue(state) do
    :ok = Queue.clear()
    %{state | queue: [], queue_selected: 0, status: {:info, "Queue cleared"}}
  end

  # Enter in the modal starts playback from the head, origin :queue, so the
  # `:play_result` handler auto-advances through the rest (see Playmark.TUI). A
  # no-op on an empty queue, and ignored while already playing — the running
  # player must close first (the modal can be opened over :playing).
  defp start_queue(%{queue_return: :playing} = state), do: state

  defp start_queue(state) do
    case Queue.head() do
      nil ->
        %{state | status: {:error, "Queue is empty"}}

      item ->
        playable = %{title: item.title, url: item.url, local: item.local, author: item.author}
        start_play(playable, :queue, state, item.id)
    end
  end

  # --- history -------------------------------------------------------------

  # Open the watch-history modal, remembering the mode to restore on Esc. Reachable
  # from any browse mode, including Search and Explore, but never over the running
  # player. Refreshes the list so a
  # play recorded since mount (or a rewatch that bumped an item) shows in order.
  def open_history(state) do
    history = list_history()

    %{
      state
      | mode: :history,
        history_return: state.mode,
        history: history,
        history_selected: Nav.clamp(state.history_selected, 0, max(length(history) - 1, 0))
    }
  end

  def handle_history_key("q", state), do: {:stop, state}
  def handle_history_key("j", state), do: {:noreply, move_history(state, 1)}
  def handle_history_key("down", state), do: {:noreply, move_history(state, 1)}
  def handle_history_key("k", state), do: {:noreply, move_history(state, -1)}
  def handle_history_key("up", state), do: {:noreply, move_history(state, -1)}
  def handle_history_key("g", state), do: {:noreply, move_history(state, :top)}
  def handle_history_key("home", state), do: {:noreply, move_history(state, :top)}
  def handle_history_key("G", state), do: {:noreply, move_history(state, :bottom)}
  def handle_history_key("end", state), do: {:noreply, move_history(state, :bottom)}
  def handle_history_key("page_up", state), do: {:noreply, move_history(state, -Nav.page_step())}
  def handle_history_key("page_down", state), do: {:noreply, move_history(state, Nav.page_step())}
  def handle_history_key("d", state), do: {:noreply, confirm_remove_history(state)}
  def handle_history_key("c", state), do: {:noreply, confirm_clear_history(state)}
  def handle_history_key("enter", state), do: {:noreply, replay_selected(state)}
  # "e" appends the selected history entry to the queue tail; "n" inserts it
  # right after the current head so it plays next. History items carry their own
  # local flag, so the play path forks correctly without re-deriving it.
  def handle_history_key("e", state), do: {:noreply, enqueue_history_selected(state, :tail)}
  def handle_history_key("n", state), do: {:noreply, enqueue_history_selected(state, :next)}

  # Esc closes the modal, restoring the mode it was opened from.
  def handle_history_key("esc", state) do
    {:noreply, %{state | mode: state.history_return, status: nil}}
  end

  def handle_history_key(_code, state), do: {:noreply, state}

  defp move_history(state, target) when target in [:top, :bottom] do
    case Nav.jump_index(state.history, target) do
      nil -> state
      index -> %{state | history_selected: index}
    end
  end

  defp move_history(state, delta) do
    case state.history do
      [] ->
        state

      history ->
        %{
          state
          | history_selected: Nav.clamp(state.history_selected + delta, 0, length(history) - 1)
        }
    end
  end

  defp selected_history_item(state), do: Enum.at(state.history, state.history_selected)

  # A single-entry remove is staged behind a confirmation like the queue's, for the
  # same reasons (see confirm_remove_queued/1). The selection index survives :confirm
  # mode, so remove_history/1 resolves the same entry on "y". A no-op on empty history.
  defp confirm_remove_history(state) do
    case selected_history_item(state) do
      nil ->
        state

      item ->
        %{
          state
          | mode: :confirm,
            confirm_return: :history,
            confirm: %{action: :remove_history, prompt: "Remove \"#{item.title}\" from history?"},
            status: nil
        }
    end
  end

  defp remove_history(state) do
    case selected_history_item(state) do
      nil ->
        state

      item ->
        {:ok, _} = Impl.history().remove(item)
        history = list_history()

        %{
          state
          | history: history,
            history_selected: Nav.clamp(state.history_selected, 0, max(length(history) - 1, 0)),
            status: {:info, "Removed from history"}
        }
    end
  end

  # Clearing wipes all history in one keystroke, so it's staged behind a
  # confirmation like the queue clear. A no-op (with a hint) on empty history so the
  # prompt never appears for nothing. The clear itself runs from handle_confirm_key/2
  # on "y"; Esc/other keys return to the modal.
  defp confirm_clear_history(%{history: []} = state) do
    %{state | status: {:info, "History is already empty"}}
  end

  defp confirm_clear_history(state) do
    %{
      state
      | mode: :confirm,
        confirm_return: :history,
        confirm: %{
          action: :clear_history,
          prompt:
            "Clear all #{count_with_label(state.history, "history entry", "history entries")}?"
        },
        status: nil
    }
  end

  defp clear_history(state) do
    :ok = Impl.history().clear()
    %{state | history: [], history_selected: 0, status: {:info, "History cleared"}}
  end

  # Enter in the modal replays the selected entry. A history item carries its own
  # `local` flag, so the play path forks correctly (local file vs YouTube URL) just
  # as a direct Enter or a queue entry does. A no-op on an empty list.
  defp replay_selected(state) do
    case selected_history_item(state) do
      nil ->
        state

      item ->
        playable = %{title: item.title, url: item.url, local: item.local, author: item.author}
        start_play(playable, :history, state)
    end
  end

  # Enqueue the selected history entry (tail or play-next). Builds the same
  # source-agnostic play fields replay_selected/1 uses, so a re-fetch is never
  # needed. A no-op on an empty list.
  defp enqueue_history_selected(state, target) do
    case selected_history_item(state) do
      nil ->
        state

      item ->
        attrs = %{title: item.title, url: item.url, local: item.local, author: item.author}
        do_enqueue(state, attrs, item.title, target)
    end
  end

  # --- help ----------------------------------------------------------------

  # Moved to Playmark.TUI.HelpActions; delegated until the runtime calls it
  # directly.
  defdelegate open_help(state), to: HelpActions
  defdelegate handle_help_key(code, state), to: HelpActions

  # --- playback (bookmarks and videos) -------------------------------------

  defp play_selected(state) do
    case selected_item(state) do
      nil ->
        state

      item ->
        # A local directory's files are real paths handed straight to the player;
        # everything else is a YouTube URL that may need stream resolution first.
        # For a direct Enter the active view decides; a queue entry carries its
        # own flag (see start_play/3 and start_queue).
        playable = %{
          title: item.title,
          url: item.url,
          local: state.view == :locals,
          author: Nav.item_author(item)
        }

        start_play(playable, :list, state)
    end
  end

  # All playback enters here. A meaningful checkpoint is staged behind a prompt;
  # otherwise launch immediately. The return mode is captured before entering the
  # prompt so Search, Explore, History, nested video lists, and Queue all restore
  # exactly where the play was requested.
  def start_play(playable, origin, state, queue_id \\ nil) do
    play = Impl.playback()
    return_mode = return_mode(origin, state)

    case resume_checkpoint(play, playable.url) do
      nil ->
        launch_play(playable, origin, state, queue_id, return_mode, nil)

      checkpoint ->
        pending = %{
          playable: playable,
          origin: origin,
          queue_id: queue_id,
          return_mode: return_mode,
          display_mode: resume_display_mode(origin, state),
          position_ms: checkpoint.resume_position_ms,
          duration_ms: checkpoint.duration_ms
        }

        %{state | mode: :resume, resume: pending, playing: nil, status: nil}
    end
  end

  # Playback blocks for the external player's lifetime, so the actual facade call
  # runs in a task. Checkpoint callbacks write from that task rather than blocking
  # the TUI runtime; only visual stages and the correlated final result are sent
  # back to handle_info/2.
  defp launch_play(playable, origin, state, queue_id, return_mode, start_position_ms) do
    parent = self()
    play = Impl.playback()
    player = play.player()
    local? = playable.local
    url = playable.url
    playback_ref = make_ref()

    # Record the play the moment it begins — every play path funnels through here,
    # so this one call captures them all. Best-effort: a failed write must never
    # interrupt playback, so we ignore its result. A rewatch upserts (bumps the
    # existing row's played_at) rather than duplicating (see Playmark.History).
    safe_history(fn ->
      Impl.history().record(%{
        title: playable.title,
        url: url,
        local: local?,
        author: Map.get(playable, :author)
      })
    end)

    # Title + channel handed to the player as display metadata so it shows them
    # instead of "unknown title / unknown artist" (author is best-effort; nil for
    # local files or a failed oEmbed lookup — the backend then omits the flag).
    meta = %{title: playable.title, author: Map.get(playable, :author)}

    progress = fn
      {:checkpoint, position_ms, duration_ms} ->
        safe_history(fn -> Impl.history().save_checkpoint(url, position_ms, duration_ms) end)

      :clear_checkpoint ->
        safe_history(fn -> Impl.history().clear_checkpoint(url) end)

      stage ->
        send(parent, {:play_progress, playback_ref, stage})
    end

    {:ok, task_pid} =
      Task.start(fn ->
        result =
          try do
            if local?,
              do: play.play_local(url, meta, progress, start_position_ms),
              else: play.play(url, meta, progress, start_position_ms)
          rescue
            error -> {:error, Exception.message(error)}
          end

        send(parent, {:play_result, playback_ref, result})
      end)

    playing = %{
      ref: playback_ref,
      task_pid: task_pid,
      title: playable.title,
      player: player,
      resume_position_ms: start_position_ms,
      steps: play_steps(player, local?),
      stage: :starting,
      stream: stream_plan(player, local?),
      captions: captions_plan(player, local?),
      # Chapter count, filled in from the caption probe's {:chapters, n} report
      # (mpv/VLC with captions on). nil until then / when no probe runs.
      chapters: nil,
      origin: origin,
      queue_id: queue_id,
      return_mode: return_mode
    }

    %{state | mode: :playing, playing: playing, resume: nil, status: nil}
  end

  defp launch_pending_resume(state, start_position_ms) do
    pending = state.resume

    launch_play(
      pending.playable,
      pending.origin,
      state,
      pending.queue_id,
      pending.return_mode,
      start_position_ms
    )
  end

  defp resume_checkpoint(play, url) do
    if play.resume_supported?() do
      case safe_history(fn -> Impl.history().get_checkpoint(url) end) do
        %{resume_position_ms: position, duration_ms: duration} = checkpoint
        when is_integer(position) and is_integer(duration) and
               position >= @minimum_resume_ms and duration - position > @completion_window_ms ->
          checkpoint

        _other ->
          nil
      end
    end
  end

  defp resume_display_mode(:queue, _state), do: :queue_manage
  defp resume_display_mode(_origin, state), do: state.mode

  defp safe_history(fun) do
    fun.()
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  # What the stream step should say. `nil` when there's no :resolving step (mpv
  # drives yt-dlp itself; a local file needs no resolution) so the view omits the
  # detail. Otherwise the configured quality cap — the `:max_height` ceiling the
  # yt-dlp format selector is built around — with `result` left nil until the
  # backend reports the resolved shape (`:split` / `:muxed`, folded in by Playmark.TUI).
  # This lets the step read "up to 1080p…" up front and firm up to "1080p cap ·
  # video+audio" once resolved.
  defp stream_plan(player, false = _local?) when player in [:vlc, :ffplay],
    do: %{max_height: Playback.max_height(), result: nil}

  defp stream_plan(_player, _local?), do: nil

  # What the caption step should say. `nil` when captions won't run (a local file,
  # or subtitles disabled) so the view omits the line entirely. Otherwise the
  # configured preference chain — first-choice `default`, optional `fallback`
  # language — with `result` left nil until the backend reports what actually
  # matched (`{:manual, lang}` / `{:translated, lang}` / `{:auto, lang}` /
  # `:none`, folded in by Playmark.TUI). This lets the step read "want en
  # (fallback fr)…" up front and firm up to "en · uploader" once resolved.
  defp captions_plan(_player, true = _local?), do: nil
  defp captions_plan(:ffplay, false = _local?), do: nil

  defp captions_plan(_player, false = _local?) do
    if Playback.subtitles?() do
      %{default: Playback.subtitle_default(), fallback: Playback.subtitle_fallback(), result: nil}
    end
  end

  # The ordered stages a backend will emit for this play, used to render the
  # step-by-step panel. Kept in sync with what the backends actually report:
  # a local file goes straight to :playing; VLC and ffplay resolve URLs first;
  # captions are attempted only when enabled and supported. mpv drives yt-dlp
  # itself, so it has no :resolving stage.
  defp play_steps(_player, true = _local?), do: [:playing]

  defp play_steps(player, false = _local?) do
    resolving = if player in [:vlc, :ffplay], do: [:resolving], else: []
    captions = if player != :ffplay and Playback.subtitles?(), do: [:captions], else: []
    resolving ++ captions ++ [:playing]
  end

  defp return_mode(:search, _state), do: :search_results
  defp return_mode(:explore, _state), do: :explore
  defp return_mode(:history, state), do: state.history_return

  defp return_mode(:queue, %{playing: %{origin: :queue, return_mode: return_mode}}),
    do: return_mode

  defp return_mode(:queue, state), do: state.queue_return
  defp return_mode(:list, %{mode: :videos}), do: :videos
  defp return_mode(_origin, _state), do: :list

  # --- opening a subscription (list its videos) ----------------------------

  defp load_videos(state) do
    case selected_item(state) do
      nil ->
        state

      subscription ->
        # Opening a subscription always starts on its Videos tab; `s` later flips
        # to Streams via switch_tab/2. We canonicalize the stored URL here so the
        # channel_url held in state (and reused by switch_tab) is tab-free even for
        # a legacy subscription that still carries a `/videos` segment.
        url = YouTube.canonical_channel_url(subscription.url)
        fetch_videos_tab(state, url, subscription.name, :videos)
    end
  end

  # Re-fetches the currently-open channel's other tab in place. Only meaningful in
  # :videos mode with a channel_url set (a subscription listing, not a playlist or
  # local-file listing, which have no channel URL); a no-op otherwise, and a no-op
  # when already on the requested tab. Reuses the same async path as load_videos,
  # so a late result after Esc is dropped by the mode guard in handle_info.
  def switch_tab(%{mode: :videos, channel_url: url, video_tab: current} = state, tab)
      when is_binary(url) and tab in [:videos, :streams] and tab != current do
    fetch_videos_tab(state, url, state.channel_name, tab)
  end

  def switch_tab(state, _tab), do: state

  def open_channel_playlists(%{mode: :videos, channel_url: url} = state)
      when is_binary(url) do
    parent = self()
    request_ref = make_ref()
    chan = Impl.channel()
    name = state.channel_name

    {:ok, task_pid} =
      Task.start(fn ->
        result = safe_list_playlists(chan, url)
        send(parent, {:channel_playlists_result, request_ref, result, name, url})
      end)

    %{
      state
      | mode: :channel_playlists_loading,
        channel_playlist_channel_name: name,
        channel_playlist_channel_url: url,
        channel_playlists_return: :videos,
        channel_playlists_request_ref: request_ref,
        channel_playlists_task_pid: task_pid,
        status: {:info, "Loading playlists from #{name}… (Esc to cancel)"}
    }
  end

  def open_channel_playlists(state), do: state

  def cancel_channel_playlists(state) do
    if is_pid(state.channel_playlists_task_pid) and
         Process.alive?(state.channel_playlists_task_pid) do
      Process.exit(state.channel_playlists_task_pid, :kill)
    end

    %{
      state
      | mode: state.channel_playlists_return,
        channel_playlists_request_ref: nil,
        channel_playlists_task_pid: nil,
        status: {:info, "Canceled"}
    }
  end

  def cancel_channel_videos(state) do
    terminate_task(state.channel_task_pid)

    %{
      state
      | mode: state.loading_return,
        channel_request_ref: nil,
        channel_task_pid: nil,
        status: {:info, "Canceled"}
    }
  end

  def cancel_playlist_videos(state) do
    terminate_task(state.playlist_task_pid)

    %{
      state
      | mode: state.loading_return,
        playlist_request_ref: nil,
        playlist_task_pid: nil,
        status: {:info, "Canceled"}
    }
  end

  def cancel_local_entries(state) do
    terminate_task(state.local_task_pid)

    %{
      state
      | mode: state.loading_return,
        local_pending: nil,
        local_request_ref: nil,
        local_task_pid: nil,
        status: {:info, "Canceled"}
    }
  end

  defp terminate_task(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  defp terminate_task(_pid), do: :ok

  defp safe_list_playlists(channel, url) do
    channel.list_playlists(url)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp switch_from_channel_playlists(state, tab) do
    state
    |> Map.put(:videos_return, :list)
    |> fetch_videos_tab(
      state.channel_playlist_channel_url,
      state.channel_playlist_channel_name,
      tab
    )
  end

  defp close_channel_playlists(state) do
    %{
      state
      | mode: :list,
        channel_playlists: [],
        channel_playlist_selected: 0,
        channel_playlist_filter: "",
        channel_playlist_channel_name: nil,
        channel_playlist_channel_url: nil,
        channel_name: nil,
        channel_url: nil,
        videos: [],
        videos_return: :list,
        selected: 0,
        filter: "",
        status: nil
    }
  end

  defp restore_channel_playlists(state) do
    %{
      state
      | mode: :channel_playlists,
        videos: [],
        videos_return: :list,
        channel_name: state.channel_playlist_channel_name,
        channel_url: state.channel_playlist_channel_url,
        video_tab: :videos,
        selected: 0,
        filter: "",
        status: nil
    }
  end

  defp save_channel_playlist(%{channel_playlist_save_ref: ref} = state) when not is_nil(ref),
    do: state

  defp save_channel_playlist(state) do
    case selected_channel_playlist(state) do
      nil ->
        state

      playlist ->
        parent = self()
        impl = Impl.playlists()
        channel = state.channel_playlist_channel_name
        request_ref = make_ref()

        Task.start(fn ->
          result =
            try do
              impl.save_playlist(playlist, channel)
            rescue
              error -> {:error, Exception.message(error)}
            end

          send(parent, {:channel_playlist_save_result, request_ref, result})
        end)

        %{
          state
          | channel_playlist_save_ref: request_ref,
            status: {:info, "Saving #{playlist.title}…"}
        }
    end
  end

  # Spawns the tab fetch and drops into :loading. `url` is the canonical (tab-free)
  # channel URL; `Channel.list_videos/2` appends the tab. The result carries url +
  # tab back so handle_info can set channel_url/video_tab and, on error, keep the
  # current list on screen when we were already browsing this channel. On the
  # initial Videos fetch, a channel with no Videos tab falls back to Streams;
  # yt-dlp treats a missing explicitly-requested tab as an error even when the
  # channel has content on another tab.
  defp fetch_videos_tab(state, url, name, tab) do
    parent = self()
    chan = Impl.channel()
    request_ref = make_ref()
    label = if tab == :streams, do: "streams", else: "videos"
    fallback_to_streams? = state.mode == :list and tab == :videos

    {:ok, task_pid} =
      Task.start(fn ->
        result = safe_list_videos(chan, url, tab)

        {result, result_tab} =
          if fallback_to_streams? and missing_videos_tab?(result) do
            {safe_list_videos(chan, url, :streams), :streams}
          else
            {result, tab}
          end

        send(parent, {:videos_result, request_ref, result, name, url, result_tab})
      end)

    loading_return = if state.mode == :channel_playlists, do: :channel_playlists, else: state.mode

    %{
      state
      | mode: :loading,
        channel_request_ref: request_ref,
        channel_task_pid: task_pid,
        loading_return: loading_return,
        status: {:info, "Loading #{label} from #{name}… (Esc to cancel)"}
    }
  end

  defp safe_list_videos(channel, url, tab) do
    channel.list_videos(url, tab)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp missing_videos_tab?({:error, reason}) when is_binary(reason),
    do: String.contains?(reason, "This channel does not have a videos tab")

  defp missing_videos_tab?(_result), do: false

  # --- opening a saved YouTube playlist -----------------------------------

  defp load_playlist_videos(state) do
    case selected_item(state) do
      nil ->
        state

      playlist ->
        fetch_playlist_videos(state, playlist, :list)
    end
  end

  defp load_channel_playlist_videos(state) do
    case selected_channel_playlist(state) do
      nil -> state
      playlist -> fetch_playlist_videos(state, playlist, :channel_playlists)
    end
  end

  defp fetch_playlist_videos(state, playlist, return_mode) do
    parent = self()
    request_ref = make_ref()
    source = Impl.youtube_playlist()
    title = playlist.title
    url = playlist.url

    {:ok, task_pid} =
      Task.start(fn ->
        result =
          try do
            source.list_videos(url)
          rescue
            error -> {:error, Exception.message(error)}
          end

        send(parent, {:playlist_videos_result, request_ref, result, title})
      end)

    %{
      state
      | mode: :loading,
        playlist_request_ref: request_ref,
        playlist_task_pid: task_pid,
        playlist_return: return_mode,
        loading_return: return_mode,
        status: {:info, "Loading #{title}… (Esc to cancel)"}
    }
  end

  # --- local folder browsing -----------------------------------------------

  defp load_files(state) do
    case selected_item(state) do
      nil ->
        state

      local ->
        pending = %{
          path: local.path,
          name: local.name,
          root: local.path,
          root_name: local.name,
          stack: []
        }

        state
        |> clear_local_browser()
        |> fetch_local_entries(pending, :list)
    end
  end

  defp activate_local_entry(state) do
    case selected_item(state) do
      nil ->
        state

      %{kind: :directory} = directory ->
        parent = %{
          path: state.local_path,
          name: state.channel_name,
          entries: state.videos,
          selected: state.selected,
          filter: state.filter
        }

        pending = %{
          path: directory.path,
          name: directory.title,
          root: state.local_root,
          root_name: state.local_root_name,
          stack: [parent | state.local_stack]
        }

        fetch_local_entries(state, pending, :videos)

      _file ->
        play_selected(state)
    end
  end

  defp refresh_local_entries(state) do
    pending = %{
      path: state.local_path,
      name: state.channel_name,
      root: state.local_root,
      root_name: state.local_root_name,
      stack: state.local_stack,
      refresh: true,
      filter: state.filter,
      selected: state.selected,
      selected_id: selected_id(state)
    }

    fetch_local_entries(state, pending, :videos)
  end

  defp selected_id(state) do
    case selected_item(state) do
      nil -> nil
      item -> Map.get(item, :id)
    end
  end

  defp fetch_local_entries(state, pending, return_mode) do
    parent = self()
    local_files = Impl.local_files()
    request_ref = make_ref()

    {:ok, task_pid} =
      Task.start(fn ->
        result =
          try do
            local_files.list_entries(pending.path, pending.root)
          rescue
            error -> {:error, Exception.message(error)}
          end

        send(parent, {:local_entries_result, request_ref, result})
      end)

    %{
      state
      | mode: :loading,
        loading_return: return_mode,
        local_pending: pending,
        local_request_ref: request_ref,
        local_task_pid: task_pid,
        status: {:info, "#{local_read_action(pending)} #{pending.name}… (Esc to cancel)"}
    }
  end

  defp local_read_action(%{refresh: true}), do: "Refreshing"
  defp local_read_action(_pending), do: "Reading"

  # --- bookmarking a video -------------------------------------------------

  defp bookmark_selected_video(state) do
    case selected_item(state) do
      nil ->
        state

      video ->
        bookmark_video(video, state)
    end
  end

  defp bookmark_video(video, state) do
    parent = self()

    Task.start(fn ->
      result =
        try do
          Bookmarks.add_bookmark(video.url)
        rescue
          error -> {:error, Exception.message(error)}
        end

      send(parent, {:bookmark_video_result, result})
    end)

    %{state | status: {:info, "Bookmarking #{video.title}…"}}
  end

  # --- adding a bookmark, subscription, playlist, or local -----------------

  # Add a bookmark, subscription, playlist, or local depending on the active view,
  # off the runtime process. The task always sends a result, even on an
  # unexpected raise, so we never get stuck in :fetching.
  defp start_add(url, %{view: :bookmarks} = state) do
    parent = self()

    Task.start(fn ->
      result =
        try do
          Bookmarks.add_bookmark(url)
        rescue
          error -> {:error, Exception.message(error)}
        end

      send(parent, {:add_result, result})
    end)

    %{state | mode: :fetching, status: {:info, "Fetching metadata… (Esc to cancel)"}}
  end

  defp start_add(url, %{view: :subscriptions} = state) do
    parent = self()
    subscriptions = Impl.subscriptions()

    Task.start(fn ->
      result =
        try do
          subscriptions.add_subscription(url)
        rescue
          error -> {:error, Exception.message(error)}
        end

      send(parent, {:add_result, result, :subscription})
    end)

    %{state | mode: :fetching, status: {:info, "Adding channel… (Esc to cancel)"}}
  end

  defp start_add(url, %{view: :playlists} = state) do
    parent = self()
    playlists = Impl.playlists()

    Task.start(fn ->
      result =
        try do
          playlists.add_playlist(url)
        rescue
          error -> {:error, Exception.message(error)}
        end

      send(parent, {:add_result, result, :playlist})
    end)

    %{state | mode: :fetching, status: {:info, "Adding playlist… (Esc to cancel)"}}
  end

  defp start_add(path, %{view: :locals} = state) do
    parent = self()
    locals = Impl.locals()

    Task.start(fn ->
      result =
        try do
          locals.add_local(path)
        rescue
          error -> {:error, Exception.message(error)}
        end

      send(parent, {:add_result, result, :local})
    end)

    %{state | mode: :fetching, status: {:info, "Registering directory… (Esc to cancel)"}}
  end

  # --- helpers -------------------------------------------------------------

  # Where a canceled :fetching/:loading returns to.
  def back_mode(%{mode: :fetching}), do: :list
  def back_mode(state), do: Map.get(state, :loading_return, :list)

  defp clear_local_browser(state) do
    Map.merge(state, %{
      local_root: nil,
      local_root_name: nil,
      local_path: nil,
      local_stack: [],
      local_pending: nil,
      local_request_ref: nil,
      local_task_pid: nil
    })
  end

  defp count_with_label(items, singular, plural \\ nil) do
    count = length(items)
    label = if count == 1, do: singular, else: plural || singular <> "s"
    "#{count} #{label}"
  end

  # History list reads go through the impl seam too, so a test stub sees its own
  # recorded plays reflected in the modal.
  defp list_history, do: Impl.history().list_items()
end
