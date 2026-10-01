defmodule Playmark.Player.Control do
  @moduledoc """
  Runs mpv or VLC through a Port, monitoring its local control endpoint.

  Owns the Port lifecycle, connects to a per-play control socket (a unique Unix
  socket for mpv, an ephemeral loopback port for VLC), throttles position
  checkpoints, and classifies how playback ended as `:completed`, `:stopped`, or
  `:unknown`. `Playmark.Player.Ffplay` does not come through here — it has no
  stable control API.

  ## What the caller learns, and when

  Two things are reported through the ordinary playback progress callback
  (`Playmark.Player.Playback.report/2`), on top of the position checkpoints:

    * `{:control, :ready}` — the control socket connected. From this point the
      player can be asked to quit.
    * `{:control, :none}` — there is no socket and there will not be one: the
      connect deadline passed, or an established socket dropped. The player still
      plays; it just can't be controlled.

  Exactly one of these arrives for every mpv/VLC play. `Playmark.TUI` waits for it
  before unlocking browsing, because takeover depends on being able to deliver a
  quit — see `Playmark.TUI.PlaybackActions`.

  ## Pauses

  A third report, `{:paused, true}` / `{:paused, false}`, goes through the same
  callback. It is sent only when the state *changes*, on either player, because
  both have a way of telling you the state playback is already in: mpv pushes the
  property's current value the moment it is subscribed to, and VLC's poll answers
  the same thing every five seconds. Reporting those would read downstream as a
  resume — republishing a card and re-anchoring its bar — on every play and then
  every five seconds.

  Resuming also forces a position report, and sends it *after* the resume. Both
  halves matter: the card is republished without an anchor, so a position report
  that arrived first would be discarded; and without the force, mpv would send
  nothing at all while the position sits still, leaving the bar blank until the
  next throttled checkpoint ten seconds later.

  The two players get there differently. mpv observes the `pause` property over
  JSON IPC, so the transition arrives the instant it happens. VLC has no such
  event — its state is polled, and the `status` reply is read by
  `parse_vlc_state/1`, which acts only on `playing` and `paused` and ignores
  everything else rather than guessing. So a VLC pause is noticed up to
  `@poll_interval_ms` late, and a state this module does not recognise degrades
  to "no pause detection" rather than to a wrong card.

  ffplay is absent from all of this by construction: it has no control socket, so
  a paused ffplay is indistinguishable from a playing one.

  ## Stopping a running player

  Send `:playmark_stop` to the process running `run/4`. It writes a quit command
  to the control socket (mpv takes JSON IPC `quit`; VLC needs RC `shutdown` —
  its `quit` only ends the control session, see `request_quit/2`) and keeps
  monitoring. The player's own exit is what actually ends playback, so `finish/2`
  then classifies it as usual and the position checkpoint is written exactly as it
  would be for a user-initiated close. A stop sent to a player with no socket is a
  no-op, which is why the TUI refuses takeover unless `{:control, :ready}` arrived.
  """

  @connect_timeout_ms 5_000
  @connect_retry_ms 100
  @checkpoint_interval_ms 10_000

  # How far a sample may miss the prediction before it counts as a seek. Two
  # seconds absorbs socket and poll jitter — a VLC sample is timestamped two
  # round-trips after its position was read — while still catching a small
  # deliberate seek. Inherited from cliamp-plugin-discord-rpc's equivalent,
  # which uses the same figure against real players.
  @seek_tolerance_ms 2_000
  @minimum_position_ms 10_000
  @completion_window_ms 30_000
  @max_error_output 8_192

  # How often VLC is asked where it is. It is also the latency floor on noticing
  # a pause: VLC has no event to push, so a pause is only seen on the next poll,
  # and the card lingers for up to this long before it is cleared.
  @poll_interval_ms 5_000
  @query_timeout_ms 1_000

  @type kind :: :mpv | :vlc

  @doc """
  Launches a player through a Port and monitors its local control endpoint.

  `args_fun` receives a unique Unix socket path for mpv or loopback TCP port for
  VLC. Position and checkpoint-clear events are reported through the ordinary
  playback progress callback.

  Returns `{:ok, :stopped}` without launching when the play was already cancelled
  during preparation — see `Playmark.Player.Playback.stop_requested?/0`. That
  check is the last thing before the port opens, so a cancelled play does not
  flash a player window open and shut.
  """
  def run(kind, executable, args_fun, opts)
      when kind in [:mpv, :vlc] and is_binary(executable) and is_function(args_fun, 1) do
    cond do
      Playmark.Player.Playback.stop_requested?() ->
        {:ok, :stopped}

      path = System.find_executable(executable) ->
        run_player(kind, executable, path, args_fun, opts)

      true ->
        {:error, "#{executable} executable not found"}
    end
  end

  @doc false
  def parse_mpv_line(line) when is_binary(line) do
    with {:ok, message} <- Jason.decode(String.trim(line)) do
      case message do
        %{"event" => "property-change", "name" => "time-pos", "data" => value} ->
          {:position, milliseconds(value)}

        %{"event" => "property-change", "name" => "duration", "data" => value} ->
          {:duration, milliseconds(value)}

        %{"event" => "property-change", "name" => "seekable", "data" => value}
        when is_boolean(value) ->
          {:seekable, value}

        %{"event" => "property-change", "name" => "pause", "data" => value}
        when is_boolean(value) ->
          {:pause, value}

        %{"event" => "end-file", "reason" => reason} when is_binary(reason) ->
          {:end_file, reason}

        _other ->
          :ignore
      end
    else
      _error -> :ignore
    end
  end

  @doc false
  def parse_vlc_value(line) when is_binary(line) do
    line
    |> String.trim()
    |> String.trim_leading(">")
    |> String.trim()
    |> Integer.parse()
    |> case do
      {value, ""} when value >= 0 -> {:ok, value}
      _other -> :ignore
    end
  end

  # VLC has no pause *event*: unlike mpv, whose JSON IPC pushes a property change
  # the moment the property moves, VLC's RC interface only answers when asked, so
  # the state has to be polled for. `status` is the only thing that answers it,
  # and it replies with several lines — the state is the last, but this keys on
  # content rather than position so a shifted reply cannot make it miss.
  #
  # Only the two states a pause feature acts on are read: `playback_actions`
  # clears the card on `{:paused, true}` and republishes on `{:paused, false}`, so
  # guessing at an unrecognised state would clear the card of a video still
  # playing. `stopped`, the startup chatter, and a bare prompt are all ignored,
  # which degrades this to "no pause detection" rather than to a wrong card.
  @doc false
  def parse_vlc_state(line) when is_binary(line) do
    case Regex.run(~r/\(\s*state\s+([a-z]+)\s*\)/, line) do
      [_, "playing"] -> {:ok, :playing}
      [_, "paused"] -> {:ok, :paused}
      _other -> :ignore
    end
  end

  # Whether a position sample has jumped away from where the previous one says
  # it should be — a seek rather than playback advancing.
  #
  # Predict, then compare. `maybe_checkpoint/2` emits at most one sample per 10s
  # of movement, so a sample can be ten seconds stale; comparing a sample to the
  # previous *sample* would call that stale, and a bar re-anchored from it would
  # walk backwards every ten seconds. Comparing it to where the previous sample
  # says playback has reached *by now* does not: a stale sample is exactly what
  # the prediction describes, and a seek is the one thing that misses it —
  # however small, including a backwards seek too small to produce a sample of
  # its own.
  @doc false
  def discontinuity?(nil, _position_ms, _observed_at), do: false

  def discontinuity?(
        %{position_ms: last_position, observed_at: last_observed},
        position_ms,
        observed_at
      ) do
    expected = last_position + max(observed_at - last_observed, 0)
    abs(position_ms - expected) > @seek_tolerance_ms
  end

  # Asks a running player to exit cleanly over its control socket. A nil socket
  # (never connected, or dropped mid-play) is a no-op, and a failed send is
  # swallowed — a stop request must never crash the monitor loop, because the port
  # exit is what actually ends playback either way.
  #
  # The two players want different words, and VLC's is the non-obvious one. Its RC
  # `quit` ends the *control session*, not the player: measured against VLC 3.0.23,
  # `quit` left the process playing indefinitely and merely dropped the socket
  # (which then reported {:control, :none}, so takeover silently stopped working),
  # while `shutdown` exited it in 6ms. mpv's IPC `quit` does exit mpv (5ms), so it
  # keeps the obvious spelling.
  @doc false
  def request_quit(_kind, nil), do: :ok

  def request_quit(:mpv, socket),
    do: send_command(socket, Jason.encode!(%{command: ["quit"]}) <> "\n")

  def request_quit(:vlc, socket), do: send_command(socket, "shutdown\n")

  defp send_command(socket, command) do
    _ignored = :gen_tcp.send(socket, command)
    :ok
  end

  defp run_player(kind, executable, executable_path, args_fun, opts) do
    control_endpoint = control_endpoint(kind)
    cleanup_endpoint(kind, control_endpoint)

    port =
      Port.open({:spawn_executable, executable_path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args_fun.(control_endpoint)
      ])

    state = %{
      kind: kind,
      executable: executable,
      port: port,
      socket: nil,
      control_endpoint: control_endpoint,
      position_ms: nil,
      duration_ms: nil,
      seekable: kind == :vlc,
      paused: false,
      end_reason: nil,
      pending: nil,
      poll_ref: nil,
      last_checkpoint_ms: nil,
      last_sample: nil,
      output: "",
      opts: opts
    }

    try do
      wait_for_socket(state, monotonic_ms() + @connect_timeout_ms)
    after
      close_port(port)
      cleanup_endpoint(kind, control_endpoint)
    end
  end

  defp wait_for_socket(state, deadline) do
    case connect(state.kind, state.control_endpoint) do
      {:ok, socket} ->
        state
        |> Map.put(:socket, socket)
        |> initialize_control()
        |> report_control(:ready)
        |> monitor()

      {:error, _reason} ->
        receive do
          {port, {:data, data}} when port == state.port ->
            state
            |> append_output(data)
            |> retry_or_monitor(deadline)

          {port, {:exit_status, status}} when port == state.port ->
            finish(state, status)
        after
          @connect_retry_ms -> retry_or_monitor(state, deadline)
        end
    end
  end

  defp retry_or_monitor(state, deadline) do
    if monotonic_ms() < deadline do
      wait_for_socket(state, deadline)
    else
      # The connect deadline passed: this player runs without a control socket,
      # so it can never be asked to quit. Say so, rather than leaving the caller
      # waiting for a readiness report that will never come.
      state |> report_control(:none) |> monitor()
    end
  end

  # Tells the caller whether the player can be controlled — `:ready` once its
  # socket is up, `:none` when there is no socket and never will be. The TUI
  # gates takeover on this, and keeps browsing locked until one of them arrives
  # (see Playmark.TUI.PlaybackActions).
  defp report_control(state, control) do
    Playmark.Player.Playback.report(state.opts, {:control, control})
    state
  end

  defp connect(:mpv, path) do
    :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: true], 250)
  end

  defp connect(:vlc, port) do
    :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :line, active: true], 250)
  end

  defp initialize_control(%{kind: :mpv, socket: socket} = state) do
    Enum.each(
      [{1, "time-pos"}, {2, "duration"}, {3, "seekable"}, {4, "pause"}],
      fn {id, property} ->
        command = Jason.encode!(%{command: ["observe_property", id, property]}) <> "\n"
        :ok = :gen_tcp.send(socket, command)
      end
    )

    state
  end

  defp initialize_control(%{kind: :vlc} = state), do: schedule_poll(state, 0)

  defp monitor(state) do
    receive do
      {port, {:data, data}} when port == state.port ->
        state |> append_output(data) |> monitor()

      {port, {:exit_status, status}} when port == state.port ->
        finish(state, status)

      {:tcp, socket, line} when socket == state.socket ->
        state |> handle_control_line(line) |> monitor()

      {:tcp_closed, socket} when socket == state.socket ->
        state
        |> Map.put(:socket, nil)
        |> Map.put(:poll_ref, nil)
        |> report_control(:none)
        |> monitor()

      {:tcp_error, socket, _reason} when socket == state.socket ->
        state
        |> Map.put(:socket, nil)
        |> Map.put(:poll_ref, nil)
        |> report_control(:none)
        |> monitor()

      # The TUI is replacing this play, or quitting. Ask the player to exit
      # cleanly; its port exit is what actually ends playback, and finish/2 then
      # classifies it as :stopped and checkpoints the position as usual.
      :playmark_stop ->
        request_quit(state.kind, state.socket)
        monitor(state)

      {:control_poll, ref} when ref == state.poll_ref ->
        state |> poll_vlc() |> monitor()

      {:control_query_timeout, ref} when ref == state.poll_ref ->
        state
        |> Map.put(:pending, nil)
        |> schedule_poll(@query_timeout_ms)
        |> monitor()

      _other ->
        monitor(state)
    end
  end

  defp handle_control_line(%{kind: :mpv} = state, line) do
    case parse_mpv_line(line) do
      {:position, position_ms} ->
        # Observed before the checkpoint, not after: a seek must be reported as
        # soon as it is seen rather than held behind one that is not due.
        state
        |> Map.put(:position_ms, position_ms)
        |> observe_position()
        |> maybe_checkpoint(false)

      {:duration, duration_ms} ->
        state |> Map.put(:duration_ms, duration_ms) |> maybe_checkpoint(false)

      {:seekable, seekable} ->
        state |> Map.put(:seekable, seekable) |> maybe_checkpoint(false)

      {:end_file, reason} ->
        state |> Map.put(:end_reason, reason) |> maybe_checkpoint(false)

      {:pause, paused} ->
        handle_pause(state, paused)

      :ignore ->
        maybe_checkpoint(state, false)
    end
  end

  # The state is the *last* of the lines a status reply carries, so the earlier
  # ones are read past rather than ending the cycle — anything that stops short
  # of a recognised state leaves `pending` alone and lets the next line through.
  # If the reply never gets there, the query timeout resets the cycle as it does
  # for a missing `get_time` answer.
  #
  # This clause sits above the position one deliberately: that clause matches any
  # pending step, so below it this state reply would be swallowed by its `_other`
  # arm and never parsed.
  #
  # The position sample is taken here, at the end of the cycle, rather than where
  # the position arrives: `get_length` answers one line later, so at the position
  # step the duration is still the previous cycle's. By the time the `status`
  # line ends the cycle both are this cycle's, and consecutive observations are
  # then a uniform `@poll_interval_ms` apart — which is what the drift test
  # interpolates over.
  defp handle_control_line(%{kind: :vlc, pending: :state} = state, line) do
    case parse_vlc_state(line) do
      {:ok, state_name} ->
        state
        |> report_vlc_state(state_name)
        |> maybe_checkpoint(resumed?(state, state_name))
        |> observe_position()
        |> Map.put(:pending, nil)
        |> schedule_poll(@poll_interval_ms)

      :ignore ->
        state
    end
  end

  defp handle_control_line(%{kind: :vlc, pending: pending} = state, line) do
    case {pending, parse_vlc_value(line)} do
      {:time, {:ok, seconds}} ->
        :ok = :gen_tcp.send(state.socket, "get_length\n")
        %{state | position_ms: seconds * 1_000, pending: :length}

      {:length, {:ok, seconds}} ->
        # The state query rides along with the position one that is happening
        # anyway, so a pause costs a command rather than a second timer.
        :ok = :gen_tcp.send(state.socket, "status\n")

        state
        |> Map.put(:duration_ms, seconds * 1_000)
        |> Map.put(:pending, :state)

      _other ->
        state
    end
  end

  # Resuming forces a position report for the same reason mpv's does, and it is
  # written *after* the resume is reported for the same reason too: republishing
  # resets the anchor, so a position report that arrived first would be thrown
  # away and the bar would sit blank until the next poll.
  defp resumed?(%{paused: true}, :playing), do: true
  defp resumed?(_state, _state_name), do: false

  # A pause or a resume is reported only when it *changes* what we believed.
  # mpv emits the property's current value the moment it is subscribed to, so
  # reporting every observation would announce a resume on every play — the card
  # would be republished and the bar re-anchored before playback even started.
  #
  # Resuming also forces the position report the card re-anchors to, because mpv
  # sends nothing of its own while the position is not moving. A pause does not
  # force one: it is about to clear the card, so a fresher checkpoint would be
  # written for nobody.
  #
  # The stage is reported *before* that forced checkpoint, and the order is
  # load-bearing: republishing resets the anchor, so a position report that
  # arrived first would be discarded and the bar would stay blank until the next
  # throttled checkpoint — up to ten seconds of a card with no progress on it.
  defp handle_pause(%{paused: paused} = state, paused), do: maybe_checkpoint(state, false)

  defp handle_pause(state, paused) do
    Playmark.Player.Playback.report(state.opts, {:paused, paused})

    state
    |> Map.put(:paused, paused)
    |> maybe_checkpoint(not paused)
  end

  # Only a change is reported, for the same reason mpv's initial observation is
  # ignored: `playback_actions` reads a resume as "republish and re-anchor". A
  # poll that keeps answering `playing` is the state playback is already in, not
  # a resume — and since the poll repeats every few seconds, reporting every
  # answer would re-anchor the bar on each one.
  defp report_vlc_state(%{paused: paused} = state, state_name) do
    paused? = state_name == :paused

    if paused == paused? do
      state
    else
      Playmark.Player.Playback.report(state.opts, {:paused, paused?})
      %{state | paused: paused?}
    end
  end

  defp poll_vlc(%{kind: :vlc, socket: socket} = state) when not is_nil(socket) do
    case :gen_tcp.send(socket, "get_time\n") do
      :ok ->
        ref = make_ref()
        Process.send_after(self(), {:control_query_timeout, ref}, @query_timeout_ms)
        %{state | pending: :time, poll_ref: ref}

      {:error, _reason} ->
        %{state | socket: nil, pending: nil, poll_ref: nil}
    end
  end

  defp poll_vlc(state), do: %{state | poll_ref: nil}

  defp schedule_poll(%{socket: nil} = state, _delay), do: state

  defp schedule_poll(state, delay) do
    ref = make_ref()
    Process.send_after(self(), {:control_poll, ref}, delay)
    %{state | poll_ref: ref}
  end

  # Records a position sample and reports it as a discontinuity when it does not
  # match where the previous sample says playback should be.
  #
  # A sample is only taken when the duration is known and non-zero: a bar needs
  # both ends, and a live stream has no end to draw. A missing position (mpv
  # reports `time-pos` as null around a seek) leaves the previous sample in
  # place, so the next real sample still compares against the position before
  # the gap.
  #
  # Public and `@doc false` for the same reason `parse_vlc_state/1` is: it is the
  # testable core of a private clause that a live socket drives.
  @doc false
  def observe_position(%{position_ms: position, duration_ms: duration} = state)
      when is_integer(position) and is_integer(duration) and duration > 0 do
    observed_at = monotonic_ms()

    if discontinuity?(state.last_sample, position, observed_at) do
      Playmark.Player.Playback.report(state.opts, {:seek, position, duration})
    end

    %{state | last_sample: %{position_ms: position, observed_at: observed_at}}
  end

  def observe_position(state), do: state

  defp maybe_checkpoint(state, force?) do
    with true <- state.seekable,
         position when is_integer(position) <- state.position_ms,
         duration when is_integer(duration) and duration > 0 <- state.duration_ms,
         true <- force? or checkpoint_due?(state.last_checkpoint_ms, position) do
      event = checkpoint_event(position, duration)
      Playmark.Player.Playback.report(state.opts, event)
      %{state | last_checkpoint_ms: position}
    else
      _other -> state
    end
  end

  defp checkpoint_due?(nil, position), do: position >= @minimum_position_ms

  defp checkpoint_due?(last_position, position),
    do: abs(position - last_position) >= @checkpoint_interval_ms

  defp checkpoint_event(position, duration) do
    if position >= @minimum_position_ms and duration - position > @completion_window_ms do
      {:checkpoint, position, duration}
    else
      :clear_checkpoint
    end
  end

  defp finish(state, status) do
    close_socket(state.socket)

    cond do
      status != 0 ->
        state = maybe_checkpoint(state, true)
        {:error, error_message(state, status)}

      completed?(state) ->
        Playmark.Player.Playback.report(state.opts, :clear_checkpoint)
        {:ok, :completed}

      valid_position?(state) ->
        _state = maybe_checkpoint(state, true)
        {:ok, :stopped}

      true ->
        {:ok, :unknown}
    end
  end

  defp completed?(%{kind: :mpv, end_reason: "eof"}), do: true

  defp completed?(%{position_ms: position, duration_ms: duration})
       when is_integer(position) and is_integer(duration) and duration > 0,
       do: duration - position <= @completion_window_ms

  defp completed?(_state), do: false

  defp valid_position?(%{seekable: true, position_ms: position, duration_ms: duration}),
    do: is_integer(position) and is_integer(duration) and duration > 0

  defp valid_position?(_state), do: false

  defp error_message(state, status) do
    detail = String.trim(state.output)
    suffix = if detail == "", do: "", else: ": #{detail}"
    "#{state.executable} exited with #{status}#{suffix}"
  end

  defp append_output(state, data) do
    output = state.output <> data
    size = byte_size(output)

    output =
      if size > @max_error_output,
        do: binary_part(output, size - @max_error_output, @max_error_output),
        else: output

    %{state | output: output}
  end

  defp milliseconds(value) when is_number(value) and value >= 0, do: round(value * 1_000)
  defp milliseconds(_value), do: nil

  defp control_endpoint(:mpv) do
    unique = System.unique_integer([:positive, :monotonic])
    Path.join(System.tmp_dir!(), "playmark-mpv-#{unique}.sock")
  end

  defp control_endpoint(:vlc) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)
    port
  end

  defp cleanup_endpoint(:mpv, path), do: File.rm(path)
  defp cleanup_endpoint(:vlc, _port), do: :ok

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp close_socket(nil), do: :ok
  defp close_socket(socket), do: :gen_tcp.close(socket)

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  catch
    :error, :badarg -> :ok
  end
end
