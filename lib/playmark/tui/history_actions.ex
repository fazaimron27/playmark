defmodule Playmark.TUI.HistoryActions do
  @moduledoc """
  The watch-history modal: replaying, enqueueing, and pruning past plays.

  History is written from `Playmark.TUI.PlaybackActions.start_play/4` — nothing
  here records a play. This module only reads the log back and acts on it.

  Like the queue it stores *content* rather than a handle, so each row carries
  the `%{title, url, local, author}` fields the play path needs and a replay
  never re-fetches. Unlike the queue, a rewatch upserts on the URL rather than
  appending, so the list holds one row per video (see `Playmark.History`).

  The modal shape mirrors `Playmark.TUI.QueueActions` — open over a browse mode,
  Esc restores it, destructive keys stage through `:confirm` — with one
  difference: it is never opened over the running player.
  """

  alias Playmark.TUI.{Impl, Nav, PlaybackActions, QueueActions}

  @doc """
  Opens the watch-history modal, remembering the mode to restore on Esc.

  Reachable from any browse mode, including Search and Explore, but never over
  the running player. Refreshes the list so a play recorded since mount (or a
  rewatch that bumped an item) shows in order.
  """
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

  # --- pruning --------------------------------------------------------------

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

  @doc false
  def remove_history(state) do
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

  @doc false
  def clear_history(state) do
    :ok = Impl.history().clear()
    %{state | history: [], history_selected: 0, status: {:info, "History cleared"}}
  end

  # --- replaying and enqueueing ---------------------------------------------

  # Enter in the modal replays the selected entry. A history item carries its own
  # `local` flag, so the play path forks correctly (local file vs YouTube URL) just
  # as a direct Enter or a queue entry does. A no-op on an empty list.
  defp replay_selected(state) do
    case selected_history_item(state) do
      nil ->
        state

      item ->
        playable = %{title: item.title, url: item.url, local: item.local, author: item.author}
        PlaybackActions.start_play(playable, :history, state)
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
        QueueActions.enqueue(state, attrs, item.title, target)
    end
  end

  # History list reads go through the impl seam too, so a test stub sees its own
  # recorded plays reflected in the modal.
  defp list_history, do: Impl.history().list_items()

  defp count_with_label(items, singular, plural) do
    count = length(items)
    label = if count == 1, do: singular, else: plural || singular <> "s"
    "#{count} #{label}"
  end
end
