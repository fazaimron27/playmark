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
  sent back to `Playmark.TUI.handle_info/2` — which forwards them straight back
  here, to `handle_progress/2` and `handle_result/2`. Position checkpoints are
  written from inside that task so they never block the runtime.

  ## Playback is a background activity

  `:playing` is a *preparation* mode, not a terminal one. It locks input only
  while the stream resolves and captions download; once the player is up,
  `handle_progress/2` restores the browse mode while `state.playing` stays
  populated. "A player is running" and "the TUI is locked" are therefore separate
  facts, which is what lets the user keep browsing.

  The player is up when two things have happened: the backend reported the
  `:playing` stage, and `Playmark.Player.Control` settled whether its socket
  exists (`playing.control` leaves `:pending`). Both are required because the
  backends report `:playing` *before* `Control.run/4` opens the port, so that
  stage alone does not mean a quit can be delivered — and takeover depends on it.

  Starting a play while one runs replaces it: `launch_play/6` asks the outgoing
  player to quit, which makes `Control` classify it as stopped and write its
  resume checkpoint. The stop lives there rather than in `start_play/4` because a
  resume prompt sits between the two, and cancelling that prompt must not have
  killed anything. A player with no control socket (ffplay, or a socket that never
  came) refuses takeover instead — see `takeover/2`.

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
  alias Playmark.YouTube

  # A checkpoint is only worth offering when there's a meaningful amount both
  # behind and ahead of it: at least @minimum_resume_ms watched, and more than
  # @completion_window_ms still to go (otherwise it's effectively finished).
  @minimum_resume_ms 10_000
  @completion_window_ms 30_000

  # How long the quit path waits for the player to report its exit. See
  # stop_player/1 — this bounds the one place we block the runtime on purpose.
  @stop_timeout_ms 3_000

  # --- stopping on the way out ---------------------------------------------

  @doc """
  Abandons a play that is still preparing, releasing the UI.

  Preparation is not the brief wait it was once documented as: on VLC with
  captions on it is a `yt-dlp -g` resolve, a `yt-dlp -J` probe, a caption fetch,
  and a socket connect — tens of seconds on one measured video, and over a minute
  when the probe was cold. Every key was dropped for that whole window, so `Esc`
  cancels it like every other loading mode in the app.

  Cancel means *stop waiting*, not *kill*: a `System.cmd` child outlives its
  killed `Task` (verified), so the yt-dlp process runs to completion and dies
  writing to a closed pipe. Clearing `playing` makes the ref guards in
  `handle_progress/2` and `handle_result/2` drop whatever it eventually reports —
  the same trade the `:fetching` / `:loading` modes already make.

  The stop message is what keeps a cancelled play from launching at all. The task
  is blocked in `System.cmd` and cannot act on it there, so both launch points
  read the mailbox immediately before starting a player
  (`Playmark.Player.Playback.stop_requested?/0`) and return without one. A stop
  landing after that check is still honoured by `Control`'s monitor loop, as
  before.

  A queued item is deliberately *not* removed and the queue does not advance:
  cancelling is not completing.
  """
  def cancel_play(%{mode: :playing, playing: playing} = state) when is_map(playing) do
    send_stop(playing)

    %{
      state
      | mode: play_return_mode(state),
        playing: nil,
        status: {:info, "Canceled"}
    }
  end

  def cancel_play(state), do: state

  @doc """
  Asks the running player to stop, leaving the TUI running.

  Unlike `stop_player/1` this does not wait: the TUI stays up, so the playback
  task delivers its `{:play_result, …}` normally and `handle_result/2` clears
  `playing` and writes the checkpoint. `playing` is deliberately *not* cleared
  here — the player is still up until it actually exits, and claiming otherwise
  would blank the strip while the video is still on screen.

  A player with no control socket can't be asked, so it reports instead of
  pretending — same rule as `takeover/2`.
  """
  def stop_playing(%{playing: %{control: :ready}} = state) do
    Impl.presence().clear()
    stop_current(state)
    %{state | status: {:info, "Stopping playback…"}}
  end

  def stop_playing(%{playing: %{player: player}} = state),
    do: %{state | status: {:error, "#{player} can't be interrupted"}}

  def stop_playing(state), do: state

  @doc """
  Stops the running player, waits briefly for it to report, and clears it.

  Called straight from `q`, without a confirmation: `X` (`stop_playing/1`) is the
  key whose job is stopping playback, and prompting here would duplicate it while
  offering a choice that isn't real — the player goes down with the VM either way.
  What the wait buys is the *position*, not the choice.

  This is the one place the TUI blocks its own runtime on purpose. The resume
  checkpoint is written *inside* the playback task (see
  `Playmark.Player.Control.finish/2`), so returning immediately would let the VM
  halt before that write lands and silently lose the user's position. The wait is
  bounded, so a player that ignores `quit` delays the exit by at most
  #{@stop_timeout_ms}ms instead of hanging it. Defensible only because the UI is
  about to disappear anyway.
  """
  def stop_player(%{playing: %{ref: ref}} = state) do
    # Sent before the wait, not after: the VM halts as soon as this returns, and
    # a cast queued behind the halt would never be handled. If it is lost anyway,
    # the socket closes with the process and Discord clears the card itself.
    Impl.presence().clear()
    stop_current(state)
    await_stop(ref)
    %{state | playing: nil}
  end

  def stop_player(state), do: %{state | playing: nil}

  defp await_stop(ref) do
    receive do
      {:play_result, ^ref, _result} -> :ok
    after
      @stop_timeout_ms -> :ok
    end
  end

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
    # `playing` is untouched: a player may still be running behind this prompt,
    # and cancelling a *different* video's resume must not disturb it.
    {:noreply,
     %{
       state
       | mode: pending.display_mode,
         resume: nil,
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
    case takeover(state, playable) do
      {:refuse, message} -> %{state | status: {:error, message}}
      :ok -> start_playable(playable, origin, state, queue_id)
    end
  end

  # What a play request means when a player is already running. Decided here,
  # before the resume prompt, so a refusal never arrives *after* a question — and
  # before any stop is sent, so cancelling the prompt leaves the player alone.
  #
  # Replacing a video with itself would read its own checkpoint, stop it (writing
  # a fresh one), then start from the stale position, so it is refused outright
  # rather than ordered around.
  defp takeover(%{playing: nil}, _playable), do: :ok
  defp takeover(%{playing: %{url: url}}, %{url: url}), do: {:refuse, "Already playing"}
  defp takeover(%{playing: %{control: :ready}}, _playable), do: :ok

  defp takeover(%{playing: %{player: player}}, _playable),
    do: {:refuse, "#{player} can't be interrupted — press e to queue"}

  defp takeover(_state, _playable), do: :ok

  defp start_playable(playable, origin, state, queue_id) do
    play = Impl.playback()
    return_mode = return_mode(origin, state)
    checkpoint = resume_checkpoint(play, playable.url)

    cond do
      is_nil(checkpoint) ->
        launch_play(playable, origin, state, queue_id, return_mode, nil)

      # The queue never stops to ask. It is unattended sequential playback, so a
      # modal prompt — whether from `Enter` in the modal or from an auto-advance
      # landing while the user browses — would steal focus from whatever is on
      # screen. A checkpoint is simply honoured.
      origin == :queue ->
        launch_play(
          playable,
          origin,
          state,
          queue_id,
          return_mode,
          checkpoint.resume_position_ms
        )

      true ->
        pending = %{
          playable: playable,
          origin: origin,
          queue_id: queue_id,
          return_mode: return_mode,
          display_mode: state.mode,
          position_ms: checkpoint.resume_position_ms,
          duration_ms: checkpoint.duration_ms
        }

        # `playing` is deliberately left as-is: a player may still be running
        # behind this prompt, and answering Esc must leave it untouched.
        %{state | mode: :resume, resume: pending, status: nil}
    end
  end

  # Playback blocks for the external player's lifetime, so the actual facade call
  # runs in a task. Checkpoint callbacks write from that task rather than blocking
  # the TUI runtime; only visual stages and the correlated final result are sent
  # back to handle_info/2. `parent` is captured here, which still runs in the
  # runtime process — this is reached synchronously from handle_event/2.
  defp launch_play(playable, origin, state, queue_id, return_mode, start_position_ms) do
    # The outgoing player goes down here rather than in start_play/4, because
    # this is the point where a play actually commits. A resume prompt sits
    # between the two, and cancelling it must not have killed anything.
    stop_current(state)

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
        # Presence needs the same pair, but as a stage rather than a checkpoint:
        # the checkpoint event is a *decision* about resume (and becomes
        # `:clear_checkpoint` near the end), while this is the raw position and
        # duration. Both ride the same callback; the runtime routes them apart.
        send(parent, {:play_progress, playback_ref, {:position, position_ms, duration_ms}})

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
      # Carried for the now-playing strip, which names the channel alongside the
      # title. Best-effort, exactly like the player's artist metadata.
      author: Map.get(playable, :author),
      url: url,
      player: player,
      resume_position_ms: start_position_ms,
      steps: play_steps(player, local?),
      stage: :starting,
      # The first position report, kept so later ones do not re-anchor — and so
      # `nil` unambiguously means "no anchor has arrived". Inside `playing`
      # rather than as a new top-level key, which the state-ownership test owns.
      anchor: nil,
      # Whether this player can be asked to quit over a control socket, which is
      # what takeover needs. `:pending` until Control reports (mpv/VLC), `:none`
      # for a player that has no control interface. See seed_control/1.
      control: seed_control(player),
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

  # Asks the currently running player to exit, if there is one and it can be
  # asked. `send/2` to a finished task is a silent no-op, so this stays safe when
  # the play has already ended. An uncontrollable player is never reached here —
  # takeover/2 refuses those before a launch commits.
  defp stop_current(%{playing: %{control: :ready} = playing}), do: send_stop(playing)
  defp stop_current(_state), do: :ok

  # The bare send, with no `control` requirement. `stop_current/1` gates on
  # `:ready` because a player that reported `:none` has no socket to write to; a
  # *preparing* play is `:pending`, where the message is speculative on purpose —
  # it is only read if the player gets far enough to start monitoring.
  defp send_stop(%{task_pid: pid}) when is_pid(pid) do
    send(pid, :playmark_stop)
    :ok
  end

  defp send_stop(_playing), do: :ok

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

  # Control reports whether the player's socket came up (`:ready`) or that the
  # connect deadline passed / the socket dropped (`:none`). Either settles
  # controllability, so either may unlock browsing.
  def handle_progress(
        {:play_progress, ref, {:control, control}},
        %{playing: %{ref: ref} = playing} = state
      )
      when control in [:ready, :none] do
    {:noreply, maybe_unlock(%{state | playing: %{playing | control: control}})}
  end

  # The card is published here rather than in `start_play/4` because this is the
  # first moment a backend reports that playback actually began. A cancelled
  # preparation or a failed launch never reaches it, so a video that never
  # played is never announced.
  def handle_progress(
        {:play_progress, ref, :playing},
        %{playing: %{ref: ref} = playing} = state
      ) do
    publish_presence(playing)
    {:noreply, maybe_unlock(%{state | playing: %{playing | stage: :playing}})}
  end

  # The first position report anchors the card's countdown. Later reports are
  # already folded into `playing` and deliberately do not republish.
  def handle_progress(
        {:play_progress, ref, {:position, position_ms, duration_ms}},
        %{playing: %{ref: ref, anchor: nil} = playing} = state
      ) do
    Impl.presence().anchor(position_ms, duration_ms)
    {:noreply, %{state | playing: %{playing | anchor: {position_ms, duration_ms}}}}
  end

  def handle_progress(
        {:play_progress, ref, {:position, _position_ms, _duration_ms}},
        %{playing: %{ref: ref}} = state
      ) do
    {:noreply, state}
  end

  def handle_progress({:play_progress, ref, stage}, %{playing: %{ref: ref} = playing} = state)
      when is_map(playing) and is_atom(stage) do
    {:noreply, maybe_unlock(%{state | playing: %{playing | stage: stage}})}
  end

  def handle_progress({:play_progress, _ref, _stage}, state), do: {:noreply, state}

  # `:playing` is a *preparation* mode: it locks input only while the player is
  # starting. Once the player is up — the `:playing` stage reported and its
  # controllability settled — the browse mode is restored while `playing` stays
  # populated, so the user keeps browsing with the player running.
  #
  # `:pending` is what we wait for: takeover needs a socket to deliver `quit` on,
  # and until Control reports we don't know whether there is one. Unlocking early
  # would leave a window where replacing the video silently does nothing.
  #
  # Guarded on `mode: :playing` so a late report can't yank a user who has since
  # navigated elsewhere back to the mode the play started from.
  defp maybe_unlock(
         %{mode: :playing, playing: %{stage: :playing, control: control} = playing} = state
       )
       when control != :pending do
    %{state | mode: unlock_mode(playing)}
  end

  defp maybe_unlock(state), do: state

  # Where browsing resumes. The `:playing` clause is a floor against relocking the
  # TUI with a live player and no key that works. No live path reaches it: a return
  # mode of `:playing` could only come from an overlay opened *during* preparation
  # saving it, and preparation now accepts no keys at all. Kept because it costs
  # one line and the cost of being wrong is an unrecoverable UI.
  defp unlock_mode(%{return_mode: :playing}), do: :list
  defp unlock_mode(%{return_mode: return_mode}), do: return_mode
  defp unlock_mode(_playing), do: :list

  # Whether a player can be asked to quit over a control socket. mpv and VLC go
  # through Playmark.Player.Control, which reports when its socket is up (or that
  # it never came); ffplay has no control interface at all, so it is
  # uncontrollable from the start. Anything unrecognised is assumed
  # uncontrollable — refusing takeover is recoverable, waiting forever for a
  # report that never arrives is not.
  defp seed_control(player) when player in [:mpv, :vlc], do: :pending
  defp seed_control(_player), do: :none

  # The card is YouTube-only. A local file's path is not an http(s) URL, so it
  # fails validation here and clears instead of announcing a filename — which is
  # also why this one clause covers both "local playback" and "not a YouTube
  # URL" rather than needing a `local` flag on the playing map.
  #
  # The card's URLs are built from what `YouTube` returns, never from the raw
  # source: `validate/1` is what stands between a played row and a URL sent to
  # another process, and `video_id/1` re-derives the id by shape rather than
  # trusting the query string. Nothing here reads the filesystem or the network.
  defp publish_presence(playing) do
    case YouTube.validate(playing.url) do
      {:ok, url} ->
        Impl.presence().set_playing(%{
          title: playing.title,
          author: playing.author,
          url: url,
          video_id: YouTube.video_id(url)
        })

      {:error, _reason} ->
        Impl.presence().clear()
    end
  end

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

  The presence card is cleared first, and only for a result carrying the ref of
  the play we think is running: a superseded or cancelled play reports late, and
  its result must not wipe the card belonging to the player still on screen.

  That clearing is in this wrapper rather than in each clause below so a new way
  for a play to end cannot forget it — every ending, including a failure, leaves
  no card behind. The clauses themselves are `do_handle_result/2`, private
  because a public `handle_result/2` a caller could reach without the guard is
  the bug this shape exists to prevent.
  """
  def handle_result({:play_result, ref, _result} = msg, %{playing: %{ref: ref}} = state) do
    Impl.presence().clear()
    do_handle_result(msg, state)
  end

  def handle_result({:play_result, _ref, _result} = msg, state), do: do_handle_result(msg, state)

  defp do_handle_result(
         {:play_result, ref, {:ok, :completed}},
         %{playing: %{ref: ref, origin: :queue}} = state
       ) do
    {:noreply, complete_queued_play(state)}
  end

  # ffplay has no stable position/end-reason API, so retain its historical clean
  # exit behavior: an unknown clean exit advances the queue.
  defp do_handle_result(
         {:play_result, ref, {:ok, :unknown}},
         %{playing: %{ref: ref, origin: :queue, player: :ffplay}} = state
       ) do
    {:noreply, complete_queued_play(state)}
  end

  defp do_handle_result(
         {:play_result, ref, {:ok, reason}},
         %{playing: %{ref: ref, origin: :queue}} = state
       )
       when reason in [:stopped, :unknown] do
    {:noreply,
     %{
       state
       | mode: play_return_mode(state),
         queue: Queue.list_items(),
         playing: nil,
         status: {:info, "Playback stopped; progress saved"}
     }}
  end

  defp do_handle_result(
         {:play_result, ref, {:ok, reason}},
         %{playing: %{ref: ref}} = state
       )
       when reason in [:completed, :stopped, :unknown] do
    {:noreply, %{state | mode: play_return_mode(state), playing: nil, status: nil}}
  end

  # A queued item failed: stop the queue and surface the error, leaving the failed
  # item in place so it is visible where playback stopped. The mode returns to
  # where browsing was rather than forcing the queue modal open — playback is a
  # background activity now, and popping a modal would interrupt the user.
  defp do_handle_result(
         {:play_result, ref, {:error, reason}},
         %{playing: %{ref: ref, origin: :queue}} = state
       ) do
    Logger.error("Playback failed: #{reason}")

    {:noreply,
     %{
       state
       | mode: play_return_mode(state),
         queue: Queue.list_items(),
         playing: nil,
         status: {:error, "Playback failed: #{reason}"}
     }}
  end

  defp do_handle_result(
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

  defp do_handle_result({:play_result, _ref, _result}, state), do: {:noreply, state}

  defp complete_queued_play(%{playing: %{queue_id: id} = playing} = state) do
    Queue.remove_by_id(id)
    queue = Queue.list_items()

    # This play is over, so clear it before advancing: the next item is a fresh
    # launch, not a takeover of a player that has already exited. Its return mode
    # moves to `queue_return`, which is where return_mode/2 reads it from once
    # `playing` is gone — otherwise a chain would forget where it started.
    return_mode = Map.get(playing, :return_mode, :list)
    state = %{state | queue: queue, playing: nil, queue_return: return_mode}

    case Queue.head() do
      nil ->
        %{state | mode: finished_mode(state, return_mode), status: {:info, "Queue finished"}}

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

  # Where a finished play lands. Only meaningful while the TUI is still locked in
  # `:playing` — i.e. the player never came up, so the mode was never released
  # somewhere. Once the player was up the user is already browsing, and a play
  # finishing must not move them: playback is a background activity.
  #
  # `return_mode/2` picks the locked-case target at launch and records it on the
  # playing map, so the first clause is the real path; the second reads `videos`,
  # a browse-core key — a legacy fallback for older/forced test states, kept
  # adjacent to the function it duplicates rather than merged into it.
  defp play_return_mode(%{mode: :playing, playing: %{return_mode: return_mode}}),
    do: return_mode

  defp play_return_mode(%{mode: :playing, videos: videos}) when videos != [], do: :videos
  defp play_return_mode(%{mode: :playing}), do: :list
  defp play_return_mode(%{mode: mode}), do: mode

  # Same rule for a drained queue, except `playing` has already been cleared by
  # the time we get here, so the target is passed in rather than read off it.
  defp finished_mode(%{mode: :playing}, return_mode), do: return_mode
  defp finished_mode(%{mode: mode}, _return_mode), do: mode
end
