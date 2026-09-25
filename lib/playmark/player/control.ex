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
  @minimum_position_ms 10_000
  @completion_window_ms 30_000
  @max_error_output 8_192

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
      end_reason: nil,
      pending: nil,
      poll_ref: nil,
      last_checkpoint_ms: nil,
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
      [{1, "time-pos"}, {2, "duration"}, {3, "seekable"}],
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
        |> schedule_poll(1_000)
        |> monitor()

      _other ->
        monitor(state)
    end
  end

  defp handle_control_line(%{kind: :mpv} = state, line) do
    state =
      case parse_mpv_line(line) do
        {:position, position_ms} -> Map.put(state, :position_ms, position_ms)
        {:duration, duration_ms} -> Map.put(state, :duration_ms, duration_ms)
        {:seekable, seekable} -> Map.put(state, :seekable, seekable)
        {:end_file, reason} -> Map.put(state, :end_reason, reason)
        :ignore -> state
      end

    maybe_checkpoint(state, false)
  end

  defp handle_control_line(%{kind: :vlc, pending: pending} = state, line) do
    case {pending, parse_vlc_value(line)} do
      {:time, {:ok, seconds}} ->
        :ok = :gen_tcp.send(state.socket, "get_length\n")
        %{state | position_ms: seconds * 1_000, pending: :length}

      {:length, {:ok, seconds}} ->
        state
        |> Map.put(:duration_ms, seconds * 1_000)
        |> Map.put(:pending, nil)
        |> maybe_checkpoint(false)
        |> schedule_poll(5_000)

      _other ->
        state
    end
  end

  defp poll_vlc(%{kind: :vlc, socket: socket} = state) when not is_nil(socket) do
    case :gen_tcp.send(socket, "get_time\n") do
      :ok ->
        ref = make_ref()
        Process.send_after(self(), {:control_query_timeout, ref}, 1_000)
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
