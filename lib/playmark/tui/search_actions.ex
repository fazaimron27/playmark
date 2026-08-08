defmodule Playmark.TUI.SearchActions do
  @moduledoc """
  The Search overlay: querying YouTube and acting on the results.

  Search is Explore's near-twin — a transient list, nothing persisted, opened
  over any browse mode and restored on Esc — but it carries two things Explore
  does not, and both are why it has its own cursor and filter fields rather than
  reusing the core's.

  First, a query. It runs a four-mode sub-machine: `:search_input` collects the
  query through the shared text input, `:search_loading` waits on the task (Esc
  terminates it, not merely drops its result), `:search_results` browses, and
  `:search_filter` narrows. `S` from the results loops back to a fresh input
  without leaving the overlay.

  Second, a filter. It borrows the shared `state.input` widget for both the query
  and the filter term, but keeps its own `search_filter`/`search_selected` so a
  nested navigation preserves the page underneath — the reason every cursor move
  here resolves through `Playmark.TUI.Filter.visible_search/1` rather than the
  raw row list.

  Every row action — play, bookmark, enqueue — hands off to the shared module
  that owns it, so a search result reaches the same funnels a bookmark or a
  channel video does.
  """

  alias ExRatatui.Event
  alias Playmark.TUI.{AddActions, Filter, Impl, Nav, PlaybackActions, QueueActions}

  @doc """
  Opens the overlay in query-input mode, remembering the mode to restore on Esc.

  Clears the shared text input and every search field, so an overlay reopened
  after a previous search starts empty rather than showing stale rows.
  """
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

  @doc """
  Esc during the load: terminates the fetch and closes the overlay.

  Search terminates its task rather than merely dropping a late result; the
  request ref is cleared too, so a result that races the kill is ignored by
  `Playmark.TUI.handle_info/2`.
  """
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
      video -> AddActions.bookmark_video(video, state)
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
end
