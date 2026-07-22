defmodule Playmark.TUI.Actions do
  @moduledoc """
  State transitions for `Playmark.TUI`: the per-mode key handlers, list
  navigation, and the task spawners that shell out or hit the network.

  Every function takes the current UI state and returns either a new state map
  (for the key-handler helpers invoked internally) or the `{:noreply, state}` /
  `{:stop, state}` tuple the runtime expects (for the top-level `handle_*_key`
  entry points). Anything that could block — adding, listing videos, playback —
  is run in a spawned task that reports back to the runtime process, so the UI
  never stalls. A result arriving after a cancel is dropped by the mode guards
  in `Playmark.TUI`'s `handle_info/2`.
  """

  alias ExRatatui.Event

  alias Playmark.TUI.Filter

  alias Playmark.{
    Bookmarks,
    Channel,
    History,
    Local,
    Playback,
    Playlists,
    Queue,
    Search,
    Subscriptions,
    YouTube
  }

  # --- list mode -----------------------------------------------------------

  def handle_list_key("q", state), do: {:stop, state}
  def handle_list_key("j", state), do: {:noreply, move(state, 1)}
  def handle_list_key("down", state), do: {:noreply, move(state, 1)}
  def handle_list_key("k", state), do: {:noreply, move(state, -1)}
  def handle_list_key("up", state), do: {:noreply, move(state, -1)}
  def handle_list_key("tab", state), do: {:noreply, toggle_view(state)}
  # Search opens its query prompt with "/" (it takes a query, not a URL); the
  # other views add with "a". Each key is a no-op in the wrong view.
  def handle_list_key("/", %{view: :search} = state), do: {:noreply, start_input(state)}
  def handle_list_key("/", state), do: {:noreply, open_filter(state)}
  def handle_list_key("a", %{view: :search} = state), do: {:noreply, state}
  def handle_list_key("a", state), do: {:noreply, start_input(state)}
  def handle_list_key("d", state), do: {:noreply, confirm_delete_selected(state)}
  def handle_list_key("enter", state), do: {:noreply, activate_selected(state)}
  # "e" appends the selected item to the playback queue. A no-op in views with no
  # selectable list here (search has none in :list mode) via enqueue_selected/1.
  def handle_list_key("e", state), do: {:noreply, enqueue_selected(state)}
  # Esc clears an active filter (there's otherwise no Esc binding in :list); with
  # no filter it's a no-op. See open_filter/1 and handle_filter_key/2.
  def handle_list_key("esc", %{filter: ""} = state), do: {:noreply, state}
  def handle_list_key("esc", state), do: {:noreply, %{state | filter: "", selected: 0}}
  def handle_list_key(_code, state), do: {:noreply, state}

  # Tab cycles the four top-level views. Clear any video list / channel label
  # left over from a previous search or opened subscription so nothing stale
  # leaks into the new view.
  defp toggle_view(state) do
    next =
      case state.view do
        :bookmarks -> :subscriptions
        :subscriptions -> :search
        :search -> :local
        :local -> :bookmarks
      end

    %{state | view: next, videos: [], channel_name: nil, selected: 0, status: nil, filter: ""}
  end

  defp start_input(state) do
    # Clear any leftover text from a previous add before showing the field.
    ExRatatui.text_input_set_value(state.input, "")
    %{state | mode: :input, status: nil}
  end

  # Enter on the current list: play a bookmark, or open a subscription's videos.
  # The search view has no list in :list mode — results arrive in :videos mode —
  # so Enter there is a no-op.
  defp activate_selected(%{view: :bookmarks} = state), do: play_selected(state)
  defp activate_selected(%{view: :subscriptions} = state), do: load_videos(state)
  defp activate_selected(%{view: :local} = state), do: load_files(state)
  defp activate_selected(%{view: :search} = state), do: state

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
  defp delete_prompt(%{view: :local}, item), do: "Remove local playlist \"#{item.name}\"?"

  # --- confirmation mode ---------------------------------------------------

  # "y" performs the staged action; any other key (including "n"/Esc) cancels.
  # The action name in `confirm` decides what runs, then we drop back to the mode
  # it was invoked from. Kept as a small dispatch so new confirmable actions only
  # add a perform clause plus their confirm_* entry point.
  def handle_confirm_key("y", %{confirm: %{action: action}} = state) do
    {:noreply, perform_confirmed(action, state)}
  end

  def handle_confirm_key(_code, state), do: {:noreply, cancel_confirm(state)}

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
                selected: clamp_index(state.selected, bookmarks),
                status: {:info, "Deleted"}
            }

          :subscriptions ->
            {:ok, _} = Subscriptions.delete_subscription(item)
            subscriptions = Subscriptions.list_subscriptions()

            %{
              state
              | subscriptions: subscriptions,
                selected: clamp_index(state.selected, subscriptions),
                status: {:info, "Unsubscribed"}
            }

          :local ->
            {:ok, _} = Playlists.delete_playlist(item)
            playlists = Playlists.list_playlists()

            %{
              state
              | playlists: playlists,
                selected: clamp_index(state.selected, playlists),
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
  def handle_videos_key("enter", state), do: {:noreply, play_selected(state)}
  # Bookmarking goes through oEmbed, which only knows YouTube URLs — a local
  # file has none, so it's a no-op here with an explanatory status.
  def handle_videos_key("b", %{view: :local} = state) do
    {:noreply, %{state | status: {:info, "Bookmarking is for YouTube videos only"}}}
  end

  def handle_videos_key("b", state), do: {:noreply, bookmark_selected_video(state)}

  # "e" appends the selected video (channel/search result or local file) to the
  # playback queue, carrying its own local? flag so the play path is right later.
  def handle_videos_key("e", state), do: {:noreply, enqueue_selected(state)}

  # "s"/"v" flip an open channel listing between its Streams and Videos tabs,
  # re-fetching in place (see switch_tab/2). Only meaningful for a subscription
  # listing (channel_url set) — a no-op for a search or local-file listing, and a
  # no-op when already on the requested tab.
  def handle_videos_key("s", state), do: {:noreply, switch_tab(state, :streams)}
  def handle_videos_key("v", state), do: {:noreply, switch_tab(state, :videos)}

  # "/" opens the incremental filter over the current video list (see open_filter/1).
  def handle_videos_key("/", state), do: {:noreply, open_filter(state)}

  # Esc first clears an active filter (staying in :videos); with no filter it goes
  # back to the list we came from. The view is unchanged — a video list is only
  # ever opened from Subscriptions, Search, or Local — so keep it, clearing the
  # results.
  def handle_videos_key("esc", %{filter: filter} = state) when filter != "" do
    {:noreply, %{state | filter: "", selected: 0}}
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

  # --- filter mode ---------------------------------------------------------

  # Open the incremental filter field over the current browse list, remembering
  # the base mode to restore when it closes (:list or :videos). The current
  # `filter` term is kept, so reopening the field prefills it for editing.
  defp open_filter(state) do
    %{state | mode: :filter, filter_return: state.mode}
  end

  # Live filter over the current list: printable keys append to the term,
  # backspace deletes, Enter/Esc close the field keeping the term (an empty term
  # is no filter). After every term change the selection is reclamped into the
  # newly-narrowed list so it can never point past the last visible row.
  def handle_filter_key("enter", state), do: {:noreply, %{state | mode: state.filter_return}}
  def handle_filter_key("esc", state), do: {:noreply, %{state | mode: state.filter_return}}

  def handle_filter_key("backspace", state) do
    filter = String.slice(state.filter, 0..-2//1)
    {:noreply, reclamp_filtered(%{state | filter: filter})}
  end

  def handle_filter_key(code, state) do
    # A printable key is a single grapheme (letters, digits, space, punctuation);
    # named keys ("left", "f5", …) are longer and ignored.
    if String.length(code) == 1 do
      {:noreply, reclamp_filtered(%{state | filter: state.filter <> code})}
    else
      {:noreply, state}
    end
  end

  # Keep `selected` within the filtered list after the term changes.
  defp reclamp_filtered(state) do
    %{state | selected: clamp(state.selected, 0, max(length(current_list(state)) - 1, 0))}
  end

  # --- input mode ----------------------------------------------------------

  def handle_input_key(%Event.Key{code: "esc"}, state) do
    {:noreply, %{state | mode: :list, status: nil}}
  end

  def handle_input_key(%Event.Key{code: "enter"}, state) do
    url = state.input |> ExRatatui.text_input_get_value() |> String.trim()

    if url == "" do
      {:noreply, %{state | status: {:error, "Enter a URL first"}}}
    else
      {:noreply, start_add(url, state)}
    end
  end

  def handle_input_key(%Event.Key{code: code}, state) do
    # Forward the keystroke to the TextInput's editor (insert, backspace,
    # cursor movement, etc.), then re-render with its updated state.
    ExRatatui.text_input_handle_key(state.input, code)
    {:noreply, state}
  end

  # --- navigation ----------------------------------------------------------

  defp move(state, delta) do
    list = current_list(state)

    case list do
      [] -> state
      _ -> %{state | selected: clamp(state.selected + delta, 0, length(list) - 1)}
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

  # The channel name for an item, fed to the player as artist metadata. Its key
  # differs by source: a bookmark stores `:channel`, an enriched channel/search
  # video carries `:author`, and a local file has neither. `nil` when absent — the
  # player then sets no artist flag.
  defp item_author(item) do
    Map.get(item, :author) || Map.get(item, :channel)
  end

  # --- queue ---------------------------------------------------------------

  # Append the selected item to the playback queue, carrying the local? flag the
  # play path forks on (the active view decides it here, at enqueue time). A
  # no-op where there's nothing selectable (e.g. the search view's empty :list).
  defp enqueue_selected(state) do
    case selected_item(state) do
      nil ->
        state

      item ->
        attrs = %{
          title: item.title,
          url: item.url,
          local: state.view == :local,
          author: item_author(item)
        }

        case Queue.enqueue(attrs) do
          {:ok, _} ->
            %{state | queue: Queue.list_items(), status: {:info, "Queued: #{item.title}"}}

          {:error, _changeset} ->
            %{state | status: {:error, "Couldn't queue that item"}}
        end
    end
  end

  # Open the queue-manage modal, remembering the mode to restore on Esc. The
  # modal is reachable from a browsable list (:list/:videos) or over the running
  # player (:playing); the running item is untouched — the modal edits the
  # upcoming items only.
  def open_queue(state) do
    %{
      state
      | mode: :queue_manage,
        queue_return: state.mode,
        queue: Queue.list_items(),
        queue_selected: clamp(state.queue_selected, 0, max(length(state.queue) - 1, 0))
    }
  end

  def handle_queue_key("q", state), do: {:stop, state}
  def handle_queue_key("j", state), do: {:noreply, move_queue(state, 1)}
  def handle_queue_key("down", state), do: {:noreply, move_queue(state, 1)}
  def handle_queue_key("k", state), do: {:noreply, move_queue(state, -1)}
  def handle_queue_key("up", state), do: {:noreply, move_queue(state, -1)}
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

  defp move_queue(state, delta) do
    case state.queue do
      [] ->
        state

      queue ->
        %{state | queue_selected: clamp(state.queue_selected + delta, 0, length(queue) - 1)}
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
            queue_selected: clamp(state.queue_selected, 0, max(length(queue) - 1, 0)),
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
        confirm: %{action: :clear_queue, prompt: "Clear all #{length(state.queue)} queued items?"},
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
  # from a browsable list (:list/:videos) only — never over the running player (the
  # `H` route in Playmark.TUI is guarded to those modes). Refreshes the list so a
  # play recorded since mount (or a rewatch that bumped an item) shows in order.
  def open_history(state) do
    history = list_history()

    %{
      state
      | mode: :history,
        history_return: state.mode,
        history: history,
        history_selected: clamp(state.history_selected, 0, max(length(history) - 1, 0))
    }
  end

  def handle_history_key("q", state), do: {:stop, state}
  def handle_history_key("j", state), do: {:noreply, move_history(state, 1)}
  def handle_history_key("down", state), do: {:noreply, move_history(state, 1)}
  def handle_history_key("k", state), do: {:noreply, move_history(state, -1)}
  def handle_history_key("up", state), do: {:noreply, move_history(state, -1)}
  def handle_history_key("d", state), do: {:noreply, confirm_remove_history(state)}
  def handle_history_key("c", state), do: {:noreply, confirm_clear_history(state)}
  def handle_history_key("enter", state), do: {:noreply, replay_selected(state)}

  # Esc closes the modal, restoring the mode it was opened from.
  def handle_history_key("esc", state) do
    {:noreply, %{state | mode: state.history_return, status: nil}}
  end

  def handle_history_key(_code, state), do: {:noreply, state}

  defp move_history(state, delta) do
    case state.history do
      [] ->
        state

      history ->
        %{state | history_selected: clamp(state.history_selected + delta, 0, length(history) - 1)}
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
        {:ok, _} = history().remove(item)
        history = list_history()

        %{
          state
          | history: history,
            history_selected: clamp(state.history_selected, 0, max(length(history) - 1, 0)),
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
          prompt: "Clear all #{length(state.history)} history entries?"
        },
        status: nil
    }
  end

  defp clear_history(state) do
    :ok = history().clear()
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
        start_play(playable, :list, state)
    end
  end

  # --- playback (bookmarks and videos) -------------------------------------

  defp play_selected(state) do
    case selected_item(state) do
      nil ->
        state

      item ->
        # A local playlist's files are real paths handed straight to the player;
        # everything else is a YouTube URL that may need stream resolution first.
        # For a direct Enter the active view decides; a queue entry carries its
        # own flag (see start_play/3 and start_queue).
        playable = %{
          title: item.title,
          url: item.url,
          local: state.view == :local,
          author: item_author(item)
        }

        start_play(playable, :list, state)
    end
  end

  # Playback shells out to an external player that blocks until the user closes
  # it. Running that inside handle_event would freeze the runtime GenServer for
  # the whole time — meanwhile ex_ratatui keeps polling the terminal and queuing
  # keystrokes, which then flood in at once on close (the "laggy" burst). A task
  # keeps the runtime draining events normally.
  #
  # The backend reports its progress through a 1-arity reporter that messages the
  # runtime with `{:play_progress, stage}`; the runtime folds each stage into the
  # `playing` map so the view can show a step-by-step panel (see the seeded
  # `steps` below and `Playmark.TUI.View`). The reporter is dropped by a mode guard
  # in handle_info once we leave :playing, mirroring the other async operations.
  #
  # `playable` is a `%{title, url, local, author}` map — the source-agnostic unit
  # both a direct Enter and the queue feed in. `origin` (`:list` / `:queue`) tells
  # the `:play_result` handler where to go when the player closes: back to the
  # list, or on to the next queued item (`playing.queue_id` names the item to
  # drop). This is the ONLY playback spawn; the queue never runs two players at
  # once — the next only starts after this one's `:play_result` arrives (see
  # Playmark.TUI).
  def start_play(playable, origin, state, queue_id \\ nil) do
    parent = self()
    play = playback()
    player = play.player()
    local? = playable.local
    url = playable.url

    # Record the play the moment it begins — every play path funnels through here,
    # so this one call captures them all. Best-effort: a failed write must never
    # interrupt playback, so we ignore its result. A rewatch upserts (bumps the
    # existing row's played_at) rather than duplicating (see Playmark.History).
    _ =
      history().record(%{
        title: playable.title,
        url: url,
        local: local?,
        author: Map.get(playable, :author)
      })

    # Title + channel handed to the player as display metadata so it shows them
    # instead of "unknown title / unknown artist" (author is best-effort; nil for
    # local files or a failed oEmbed lookup — the backend then omits the flag).
    meta = %{title: playable.title, author: Map.get(playable, :author)}
    progress = fn stage -> send(parent, {:play_progress, stage}) end

    Task.start(fn ->
      result =
        try do
          if local?,
            do: play.play_local(url, meta, progress),
            else: play.play(url, meta, progress)
        rescue
          error -> {:error, Exception.message(error)}
        end

      send(parent, {:play_result, result})
    end)

    playing = %{
      title: playable.title,
      player: player,
      steps: play_steps(player, local?),
      stage: :starting,
      stream: stream_plan(player, local?),
      captions: captions_plan(local?),
      origin: origin,
      queue_id: queue_id
    }

    %{state | mode: :playing, playing: playing, status: nil}
  end

  # What the stream step should say. `nil` when there's no :resolving step (mpv
  # drives yt-dlp itself; a local file needs no resolution) so the view omits the
  # detail. Otherwise the configured quality cap — the `:max_height` ceiling the
  # yt-dlp format selector is built around — with `result` left nil until VLC
  # reports the resolved shape (`:split` / `:muxed`, folded in by Playmark.TUI).
  # This lets the step read "up to 1080p…" up front and firm up to "1080p cap ·
  # video+audio" once resolved.
  defp stream_plan(:vlc, false = _local?), do: %{max_height: Playback.max_height(), result: nil}
  defp stream_plan(_player, _local?), do: nil

  # What the caption step should say. `nil` when captions won't run (a local file,
  # or subtitles disabled) so the view omits the line entirely. Otherwise the
  # configured preference chain — first-choice `default`, optional `fallback`
  # language — with `result` left nil until the backend reports what actually
  # matched (`{:manual, lang}` / `{:auto, lang}` / `:none`, folded in by
  # Playmark.TUI). This lets the step read "want en (fallback fr)…" up front and
  # firm up to "en · uploader" once resolved.
  defp captions_plan(true = _local?), do: nil

  defp captions_plan(false = _local?) do
    if Playback.subtitles?() do
      %{default: Playback.subtitle_default(), fallback: Playback.subtitle_fallback(), result: nil}
    end
  end

  # The ordered stages a backend will emit for this play, used to render the
  # step-by-step panel. Kept in sync with what the backends actually report:
  # a local file goes straight to :playing; a VLC stream resolves URLs first
  # (:resolving); captions (:captions) are attempted only when enabled. mpv drives
  # yt-dlp itself, so it has no :resolving stage.
  defp play_steps(_player, true = _local?), do: [:playing]

  defp play_steps(player, false = _local?) do
    resolving = if player == :vlc, do: [:resolving], else: []
    captions = if Playback.subtitles?(), do: [:captions], else: []
    resolving ++ captions ++ [:playing]
  end

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
  # :videos mode with a channel_url set (a subscription listing, not a search or
  # local-file listing, which have no channel URL); a no-op otherwise, and a no-op
  # when already on the requested tab. Reuses the same async path as load_videos,
  # so a late result after Esc is dropped by the mode guard in handle_info.
  def switch_tab(%{mode: :videos, channel_url: url, video_tab: current} = state, tab)
      when is_binary(url) and tab in [:videos, :streams] and tab != current do
    fetch_videos_tab(state, url, state.channel_name, tab)
  end

  def switch_tab(state, _tab), do: state

  # Spawns the tab fetch and drops into :loading. `url` is the canonical (tab-free)
  # channel URL; `Channel.list_videos/3` appends the tab. The result carries url +
  # tab back so handle_info can set channel_url/video_tab and, on error, keep the
  # current list on screen when we were already browsing this channel.
  defp fetch_videos_tab(state, url, name, tab) do
    parent = self()
    chan = channel()
    label = if tab == :streams, do: "streams", else: "videos"

    Task.start(fn ->
      result =
        try do
          chan.list_videos(url, tab)
        rescue
          error -> {:error, Exception.message(error)}
        end

      send(parent, {:videos_result, result, name, url, tab})
    end)

    %{state | mode: :loading, status: {:info, "Loading #{label} from #{name}… (Esc to cancel)"}}
  end

  # --- opening a local playlist (list its files) ---------------------------

  defp load_files(state) do
    case selected_item(state) do
      nil ->
        state

      playlist ->
        parent = self()
        local = local()
        name = playlist.name
        path = playlist.path

        Task.start(fn ->
          result =
            try do
              local.list_files(path)
            rescue
              error -> {:error, Exception.message(error)}
            end

          send(parent, {:files_result, result, name})
        end)

        %{state | mode: :loading, status: {:info, "Reading #{name}… (Esc to cancel)"}}
    end
  end

  # --- bookmarking a video -------------------------------------------------

  defp bookmark_selected_video(state) do
    case selected_item(state) do
      nil ->
        state

      video ->
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
  end

  # --- adding a bookmark, subscription, or local playlist ------------------

  # Add a bookmark, subscription, or local playlist depending on the active view,
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
    subscriptions = subscriptions()

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

  defp start_add(path, %{view: :local} = state) do
    parent = self()
    playlists = playlists()

    Task.start(fn ->
      result =
        try do
          playlists.add_playlist(path)
        rescue
          error -> {:error, Exception.message(error)}
        end

      send(parent, {:add_result, result, :playlist})
    end)

    %{state | mode: :fetching, status: {:info, "Registering directory… (Esc to cancel)"}}
  end

  # Search reuses the input field but isn't an "add": it lists videos, so it goes
  # to :loading (like opening a subscription) and reports back its own message.
  defp start_add(query, %{view: :search} = state) do
    parent = self()
    search = search()

    Task.start(fn ->
      result =
        try do
          search.search(query)
        rescue
          error -> {:error, Exception.message(error)}
        end

      send(parent, {:search_result, result, query})
    end)

    %{state | mode: :loading, status: {:info, "Searching #{query}… (Esc to cancel)"}}
  end

  # --- helpers -------------------------------------------------------------

  # Where a canceled :fetching/:loading returns to.
  def back_mode(_state), do: :list

  defp clamp_index(index, list), do: clamp(index, 0, max(length(list) - 1, 0))

  defp clamp(n, lo, _hi) when n < lo, do: lo
  defp clamp(n, _lo, hi) when n > hi, do: hi
  defp clamp(n, _lo, _hi), do: n

  # Implementations, overridable in tests so the suite never spawns a real
  # player or shells out to yt-dlp / the network.
  defp playback, do: Application.get_env(:playmark, :playback_impl, Playback)
  defp channel, do: Application.get_env(:playmark, :channel_impl, Channel)
  defp subscriptions, do: Application.get_env(:playmark, :subscriptions_impl, Subscriptions)
  defp search, do: Application.get_env(:playmark, :search_impl, Search)
  defp playlists, do: Application.get_env(:playmark, :playlists_impl, Playlists)
  defp local, do: Application.get_env(:playmark, :local_impl, Local)
  defp history, do: Application.get_env(:playmark, :history_impl, History)

  # History list reads go through the impl seam too, so a test stub sees its own
  # recorded plays reflected in the modal.
  defp list_history, do: history().list_items()
end
