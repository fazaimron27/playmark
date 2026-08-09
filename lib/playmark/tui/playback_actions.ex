defmodule Playmark.TUI.PlaybackActions do
  @moduledoc """
  The single funnel every play routes through, and the resume prompt in front of
  it.

  `start_play/4` is where playback from every source converges — a bookmark, a
  channel or playlist video, a Search or Explore result, a queue entry, a
  history row, a local file. That convergence is deliberate: it's why one call
  records history for all of them, and why the mode to return to when the player
  exits is captured in exactly one place (`return_mode/2`).

  Playback blocks for the external player's whole lifetime, so the facade call
  runs in a spawned task. Only visual stages and the correlated final result are
  sent back to `Playmark.TUI.handle_info/2`; position checkpoints are written
  from inside that task so they never block the runtime.

  `Playmark.Player.Playback` is called two ways here. Its IO goes through
  `Playmark.TUI.Impl.playback/0` so tests can stub it; its config reads are
  called on the real module directly, because a stub implements only the IO
  half. `Playmark.TUI.Impl`'s moduledoc explains why mixing them up presents as
  a hung test rather than a failing one.
  """

  require Logger

  alias Playmark.Player.Playback
  alias Playmark.Queue
  alias Playmark.TUI.Impl

  # A checkpoint is only worth offering when there's a meaningful amount both
  # behind and ahead of it: at least @minimum_resume_ms watched, and more than
  # @completion_window_ms still to go (otherwise it's effectively finished).
  @minimum_resume_ms 10_000
  @completion_window_ms 30_000

  # --- the resume prompt ---------------------------------------------------

  @doc """
  A saved checkpoint is a three-way choice rather than a destructive yes/no
  confirmation: resume, deliberately start over, or cancel without recording a
  new history play.
  """
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

  # --- launching ------------------------------------------------------------

  @doc """
  All playback enters here. A meaningful checkpoint is staged behind a prompt;
  otherwise launch immediately. The return mode is captured before entering the
  prompt so Search, Explore, History, nested video lists, and Queue all restore
  exactly where the play was requested.
  """
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
  # back to handle_info/2. `parent` is captured here, which still runs in the
  # runtime process — this is reached synchronously from handle_event/2.
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

  # A history write must never interrupt playback, so any raise or exit is
  # swallowed. Every caller is in this module.
  defp safe_history(fun) do
    fun.()
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  # --- what the Now Playing panel will show --------------------------------

  # What the stream step should say. `nil` when there's no :resolving step (mpv
  # drives yt-dlp itself; a local file needs no resolution) so the view omits the
  # detail. Otherwise the configured quality cap — the `:max_height` ceiling the
  # yt-dlp format selector is built around — with `result` left nil until the
  # backend reports the resolved shape (`:split` / `:muxed`), folded in by
  # `handle_progress/2` below. This lets the step read "up to 1080p…" up front
  # and firm up to "1080p cap · video+audio" once resolved.
  defp stream_plan(player, false = _local?) when player in [:vlc, :ffplay],
    do: %{max_height: Playback.max_height(), result: nil}

  defp stream_plan(_player, _local?), do: nil

  # What the caption step should say. `nil` when captions won't run (a local file,
  # or subtitles disabled) so the view omits the line entirely. Otherwise the
  # configured preference chain — first-choice `default`, optional `fallback`
  # language — with `result` left nil until the backend reports what actually
  # matched (`{:manual, lang}` / `{:translated, lang}` / `{:auto, lang}` /
  # `:none`), folded in by `handle_progress/2` below. This lets the step read
  # "want en (fallback fr)…" up front and firm up to "en · uploader" once resolved.
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

  # --- committing what the player reports ----------------------------------

  @doc """
  Folds a progress report from the running backend into the `playing` map,
  called from `Playmark.TUI.handle_info/2`.

  Playback messages carry a request ref because closing one player and opening
  another can leave late Port/socket messages in the mailbox. Only the active
  play may update state. Progress remains accepted while Queue is open over the
  player, since the playing map still identifies the active request.
  """
  def handle_progress(
        {:play_progress, ref, {:caption, result}},
        %{playing: %{ref: ref, captions: captions} = playing} = state
      )
      when is_map(captions) do
    {:noreply, %{state | playing: %{playing | captions: %{captions | result: result}}}}
  end

  def handle_progress(
        {:play_progress, ref, {:stream, shape}},
        %{playing: %{ref: ref, stream: stream} = playing} = state
      )
      when is_map(stream) do
    {:noreply, %{state | playing: %{playing | stream: %{stream | result: shape}}}}
  end

  # The caption probe also reports the video's chapter count; fold it into the
  # playing map so the Now Playing panel can show it (informational only).
  def handle_progress(
        {:play_progress, ref, {:chapters, count}},
        %{playing: %{ref: ref} = playing} = state
      )
      when is_map(playing) do
    {:noreply, %{state | playing: %{playing | chapters: count}}}
  end

  def handle_progress({:play_progress, ref, stage}, %{playing: %{ref: ref} = playing} = state)
      when is_map(playing) and is_atom(stage) do
    {:noreply, %{state | playing: %{playing | stage: stage}}}
  end

  def handle_progress({:play_progress, _ref, _stage}, state), do: {:noreply, state}

  @doc """
  Commits the external player's exit, called from `Playmark.TUI.handle_info/2`.

  How a play ends depends on where it came from, which is why `origin: :queue`
  is matched ahead of the general clauses: a queued item that finished is
  removed and the queue advances, while one that was stopped or failed keeps its
  place and opens the queue modal so it can be resumed later.

  The queue-origin clauses write `queue`, `queue_selected`, and `queue_return` —
  `QueueActions`' state keys, noted as an exception in CLAUDE.md. The coupling
  is not new: `return_mode/2` below already reads `state.queue_return`, and
  advancing the queue already calls `start_play/4` from here. Having both halves
  in one file makes it visible rather than introducing it.
  """
  def handle_result(
        {:play_result, ref, {:ok, :completed}},
        %{playing: %{ref: ref, origin: :queue}} = state
      ) do
    {:noreply, complete_queued_play(state)}
  end

  # ffplay has no stable position/end-reason API, so retain its historical clean
  # exit behavior: an unknown clean exit advances the queue.
  def handle_result(
        {:play_result, ref, {:ok, :unknown}},
        %{playing: %{ref: ref, origin: :queue, player: :ffplay}} = state
      ) do
    {:noreply, complete_queued_play(state)}
  end

  def handle_result(
        {:play_result, ref, {:ok, reason}},
        %{playing: %{ref: ref, origin: :queue}} = state
      )
      when reason in [:stopped, :unknown] do
    {:noreply,
     %{
       state
       | mode: :queue_manage,
         queue_return: Map.get(state.playing, :return_mode, :list),
         queue: Queue.list_items(),
         queue_selected: 0,
         playing: nil,
         status: {:info, "Playback stopped; progress saved"}
     }}
  end

  def handle_result(
        {:play_result, ref, {:ok, reason}},
        %{playing: %{ref: ref}} = state
      )
      when reason in [:completed, :stopped, :unknown] do
    {:noreply, %{state | mode: play_return_mode(state), playing: nil, status: nil}}
  end

  # A queued item failed: stop the queue and surface the error, leaving the failed
  # item in place so it is visible where playback stopped.
  def handle_result(
        {:play_result, ref, {:error, reason}},
        %{playing: %{ref: ref, origin: :queue}} = state
      ) do
    Logger.error("Playback failed: #{reason}")

    {:noreply,
     %{
       state
       | mode: :queue_manage,
         queue_return: Map.get(state.playing, :return_mode, :list),
         queue: Queue.list_items(),
         queue_selected: 0,
         playing: nil,
         status: {:error, "Playback failed: #{reason}"}
     }}
  end

  def handle_result(
        {:play_result, ref, {:error, reason}},
        %{playing: %{ref: ref}} = state
      ) do
    Logger.error("Playback failed: #{reason}")

    {:noreply,
     %{
       state
       | mode: play_return_mode(state),
         playing: nil,
         status: {:error, "Playback failed: #{reason}"}
     }}
  end

  def handle_result({:play_result, _ref, _result}, state), do: {:noreply, state}

  defp complete_queued_play(%{playing: %{queue_id: id}} = state) do
    Queue.remove_by_id(id)
    queue = Queue.list_items()
    state = %{state | queue: queue}

    case Queue.head() do
      nil ->
        return_mode = Map.get(state.playing, :return_mode, :list)
        %{state | mode: return_mode, playing: nil, status: {:info, "Queue finished"}}

      item ->
        playable = %{title: item.title, url: item.url, local: item.local, author: item.author}
        start_play(playable, :queue, state, item.id)
    end
  end

  # --- where the player exits back to --------------------------------------

  defp return_mode(:search, _state), do: :search_results
  defp return_mode(:explore, _state), do: :explore
  defp return_mode(:history, state), do: state.history_return

  defp return_mode(:queue, %{playing: %{origin: :queue, return_mode: return_mode}}),
    do: return_mode

  defp return_mode(:queue, state), do: state.queue_return
  defp return_mode(:list, %{mode: :videos}), do: :videos
  defp return_mode(_origin, _state), do: :list

  # Where a finished play lands. `return_mode/2` above picks this at launch and
  # records it on the playing map, so the first clause is the real path; the
  # remaining two keep older/forced test states safe. The second reads `videos`,
  # a browse-core key — a legacy fallback, kept adjacent to the function it
  # duplicates rather than merged into it, which would be a rewrite.
  defp play_return_mode(%{playing: %{return_mode: return_mode}}), do: return_mode
  defp play_return_mode(%{videos: videos}) when videos != [], do: :videos
  defp play_return_mode(_state), do: :list
end
