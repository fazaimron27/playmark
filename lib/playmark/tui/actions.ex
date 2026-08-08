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

  alias Playmark.TUI.{
    Filter,
    HelpActions,
    HistoryActions,
    Impl,
    Nav,
    PlaybackActions,
    QueueActions
  }

  # Called directly, not through `Impl`: the delete paths below and URL
  # canonicalization.
  alias Playmark.{Bookmarks, Locals, Playlists, Subscriptions, YouTube}

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

  # The resume prompt lives in Playmark.TUI.PlaybackActions — it reads only
  # `state.resume`, and every path out of it launches a play.
  defdelegate handle_resume_key(code, state), to: PlaybackActions

  defp cancel_confirm(state) do
    %{state | mode: state.confirm_return, confirm: nil, status: {:info, "Canceled"}}
  end

  defp perform_confirmed(:delete_selected, state) do
    %{delete_selected(state) | mode: :list, confirm: nil}
  end

  defp perform_confirmed(:clear_queue, state) do
    %{QueueActions.clear_queue(state) | mode: :queue_manage, confirm: nil}
  end

  defp perform_confirmed(:clear_history, state) do
    %{HistoryActions.clear_history(state) | mode: :history, confirm: nil}
  end

  defp perform_confirmed(:remove_queued, state) do
    %{QueueActions.remove_queued(state) | mode: :queue_manage, confirm: nil}
  end

  defp perform_confirmed(:remove_history, state) do
    %{HistoryActions.remove_history(state) | mode: :history, confirm: nil}
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
      video -> PlaybackActions.start_play(Nav.playable_video(video), :explore, state)
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
      video -> QueueActions.enqueue(state, Nav.playable_video(video), video.title, target)
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
      video -> PlaybackActions.start_play(Nav.playable_video(video), :search, state)
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
      video -> QueueActions.enqueue(state, Nav.playable_video(video), video.title, target)
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

        QueueActions.enqueue(state, attrs, item.title, target)
    end
  end

  # Moved to Playmark.TUI.QueueActions; delegated until the runtime calls it
  # directly. `enqueue_selected/2` above stays here because it reads the browse
  # cursor and the `view == :locals` rule that decides the local? flag.
  defdelegate open_queue(state), to: QueueActions
  defdelegate handle_queue_key(code, state), to: QueueActions

  # --- history -------------------------------------------------------------

  # Moved to Playmark.TUI.HistoryActions; delegated until the runtime calls it
  # directly. Unlike the queue there is nothing left behind — no history path
  # reads the browse cursor.
  defdelegate open_history(state), to: HistoryActions
  defdelegate handle_history_key(code, state), to: HistoryActions

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

        PlaybackActions.start_play(playable, :list, state)
    end
  end

  # Moved to Playmark.TUI.PlaybackActions; delegated until the runtime calls it
  # directly. `play_selected/1` stays here because it reads the browse cursor.
  defdelegate start_play(playable, origin, state, queue_id \\ nil), to: PlaybackActions

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
end
