defmodule Playmark.Player.Control do
  @moduledoc false

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
  """
  def run(kind, executable, args_fun, opts)
      when kind in [:mpv, :vlc] and is_binary(executable) and is_function(args_fun, 1) do
    case System.find_executable(executable) do
      nil ->
        {:error, "#{executable} executable not found"}

      executable_path ->
        run_player(kind, executable, executable_path, args_fun, opts)
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
      monitor(state)
    end
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
        state |> Map.put(:socket, nil) |> Map.put(:poll_ref, nil) |> monitor()

      {:tcp_error, socket, _reason} when socket == state.socket ->
        state |> Map.put(:socket, nil) |> Map.put(:poll_ref, nil) |> monitor()

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
      Playmark.Playback.report(state.opts, event)
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
        Playmark.Playback.report(state.opts, :clear_checkpoint)
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
