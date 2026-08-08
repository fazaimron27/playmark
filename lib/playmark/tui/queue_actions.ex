defmodule Playmark.TUI.QueueActions do
  @moduledoc """
  The playback queue: enqueueing from every list, and the queue-manage modal.

  The queue is one of the two places the TUI stores *content* rather than a
  handle (history is the other). A queued row carries the source-agnostic
  `%{title, url, local, author}` fields the play path needs, so it replays
  without re-fetching — and the `local` flag is decided here, at enqueue time,
  by the view the row came from.

  `enqueue/4` is the funnel every enqueue routes through, whatever list the row
  came from. The modal it feeds opens over any browse mode *or* over the running
  player, which is why `start_queue/1`'s first clause refuses to start a second
  play; the running player must close first.

  Every destructive key here — remove one, clear all — is staged behind
  `:confirm` mode rather than acting immediately, mirroring a list delete.
  """

  alias Playmark.Queue
  alias Playmark.TUI.{Nav, PlaybackActions}

  # --- enqueueing -----------------------------------------------------------

  @doc false
  # The single funnel every enqueue routes through: `:tail` appends to the end of
  # the queue, `:next` inserts the item just after the current head so it plays
  # next. Both refresh the in-memory queue and set a status. A no-op caller (nil
  # selection) is handled before this is reached.
  def enqueue(state, attrs, title, target) do
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

  # --- the queue-manage modal -----------------------------------------------

  @doc """
  Opens the queue-manage modal, remembering the mode to restore on Esc.

  The modal is reachable from any browse mode or over the running player; the
  running player is untouched; changes affect the persisted queue.
  """
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

  # --- removing and reordering ----------------------------------------------

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

  @doc false
  def remove_queued(state) do
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

  @doc false
  def clear_queue(state) do
    :ok = Queue.clear()
    %{state | queue: [], queue_selected: 0, status: {:info, "Queue cleared"}}
  end

  # --- starting playback from the head --------------------------------------

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
        PlaybackActions.start_play(playable, :queue, state, item.id)
    end
  end

  defp count_with_label(items, singular, plural \\ nil) do
    count = length(items)
    label = if count == 1, do: singular, else: plural || singular <> "s"
    "#{count} #{label}"
  end
end
