defmodule Playmark.TUI.ExploreActions do
  @moduledoc """
  The Explore overlay: YouTube's homepage recommendations.

  A transient list with no persistence behind it — nothing here is saved, and
  the rows are re-fetched every time the overlay opens. It can open over any
  browse mode and restores that mode on Esc, like the queue and history modals,
  but unlike them it has a loading state to cancel: `cancel_explore/1` kills the
  in-flight task rather than merely dropping its result.

  It also has no filter. Search, its near-twin, keeps `search_filter` and its
  own cursor so a nested navigation can preserve the page underneath; Explore
  is a single flat list, so `/` is simply not bound in `:explore` mode.

  Every row action — play, bookmark, enqueue — hands off to the shared module
  that owns it, so an Explore row reaches the same funnels a bookmark or a
  channel video does.
  """

  alias Playmark.TUI.{AddActions, Impl, Nav, PlaybackActions, QueueActions, Status}

  @doc """
  Opens the overlay and starts the homepage fetch, remembering the mode to
  restore on Esc.

  The request ref and task pid are tracked so a cancel can terminate the task,
  and so a late result from a canceled request is dropped by
  `Playmark.TUI.handle_info/2`.
  """
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

  @doc """
  Commits the result of the fetch `open_explore/1` started, straight from
  `Playmark.TUI.handle_info/2`.

  A failure returns to `explore_return` rather than staying in the overlay —
  there is no query to correct, so an empty Explore page has nothing to offer.
  (Search differs: it drops back to `:search_input`.)
  """
  def handle_result(
        {:explore_result, ref, {:ok, videos}},
        %{mode: :explore_loading, explore_request_ref: ref} = state
      ) do
    status =
      if videos == [],
        do: {:info, "No recommendations found"},
        else: {:info, Status.count_with_label(videos, "recommendation")}

    {:noreply,
     %{
       state
       | mode: :explore,
         explore_videos: videos,
         explore_selected: 0,
         explore_request_ref: nil,
         explore_task_pid: nil,
         status: status
     }}
  end

  def handle_result(
        {:explore_result, ref, {:error, reason}},
        %{mode: :explore_loading, explore_request_ref: ref} = state
      ) do
    {:noreply,
     %{
       state
       | mode: state.explore_return,
         explore_request_ref: nil,
         explore_task_pid: nil,
         status: {:error, "Explore failed: #{reason}"}
     }}
  end

  # A canceled or superseded Explore request must not replace a newer page.
  def handle_result({:explore_result, _ref, _result}, state), do: {:noreply, state}

  @doc """
  Esc during the load: terminates the fetch and returns to the mode Explore was
  opened from.
  """
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
      video -> AddActions.bookmark_video(video, state)
    end
  end

  defp enqueue_explore_selected(state, target) do
    case selected_explore_video(state) do
      nil -> state
      video -> QueueActions.enqueue(state, Nav.playable_video(video), video.title, target)
    end
  end
end
