defmodule Playmark.Presence.Client do
  @moduledoc """
  Speaks Discord's local IPC protocol: connect, handshake, `SET_ACTIVITY`, clear.

  Knows nothing about playback — it takes an activity map and puts it on the
  wire. The one thing it does decide is *which* socket is worth talking to:
  candidates come from `Playmark.Presence.Socket` and each must be owned by our
  own uid before it is dialled.

  ## No background reader

  Frames are read only while a command is in flight, so a socket that dies while
  the user is idle is discovered on the next write. That is a deliberate trade
  from the reference implementation: it removes a reader process, its own
  failure modes, and the question of what it does while nothing is happening.
  The cost is that a dead connection is noticed up to one keepalive late, which
  the caller's 15-second republish makes invisible in practice.

  ## Errors

  Every failure is a short string suitable for a status line. Paths are never
  named in those strings: a candidate that exists and is refused is often a
  socket planted by another user in a world-writable directory, and reporting
  its path would be advice to an attacker. `mix playmark.debug --presence`
  prints the candidate trace in order, which is where a path is worth naming.
  """

  alias Playmark.Presence.{Frame, Socket}

  # A slow local socket is a broken one; Discord answers instantly when it is up.
  @timeout_ms 2_000
  @dial_timeout_ms 500

  # How many frames to skip while waiting for the one we want. Bounded so a
  # chatty or hostile peer cannot spin this forever.
  @max_frames 8

  @unavailable "Discord unavailable"

  @type conn :: %{socket: :gen_tcp.socket(), next_nonce: pos_integer(), pid: integer()}

  @doc """
  Connects to the first usable Discord socket and completes the handshake.

  `candidates` defaults to every path `Socket.candidates/0` finds; tests pass
  their own so no real Discord is required.
  """
  def connect(client_id, candidates \\ Socket.candidates()) do
    Enum.reduce_while(candidates, {:error, @unavailable}, fn path, acc ->
      case candidate(path, client_id) do
        {:ok, conn} -> {:halt, {:ok, conn}}
        :skip -> {:cont, acc}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end

  @doc """
  Publishes `activity`, or clears the card when it is `nil`.

  Returns the connection with its nonce advanced; the reply is correlated by
  exact string equality against the nonce we sent.
  """
  def set_activity(%{socket: socket, next_nonce: nonce, pid: pid} = conn, activity) do
    sent = Integer.to_string(nonce)

    payload = %{
      "cmd" => "SET_ACTIVITY",
      "nonce" => sent,
      "args" => %{"pid" => pid, "activity" => activity}
    }

    with :ok <- send_frame(socket, Frame.frame(), payload),
         :ok <- await_ack(socket, sent, @max_frames) do
      {:ok, %{conn | next_nonce: nonce + 1}}
    end
  end

  @doc "Clears the card. Equivalent to `set_activity(conn, nil)`."
  def clear(conn), do: set_activity(conn, nil)

  @doc "Closes the connection. Safe to call on a socket that already died."
  def close(%{socket: socket}) do
    :gen_tcp.close(socket)
    :ok
  end

  @doc """
  Reads one frame.

  Public because the reader is the part worth testing directly: it must
  reassemble a frame whose header and body arrive in separate packets, and must
  refuse a declared length above the cap *before* allocating for it.
  """
  def recv_frame(socket) do
    case :gen_tcp.recv(socket, 8, @timeout_ms) do
      {:ok, header} -> decode_header(socket, header)
      {:error, reason} -> {:error, reason}
    end
  end

  # --- connecting -----------------------------------------------------------

  # A candidate is skipped — not failed — when it is absent or not ours, so the
  # loop keeps looking. Only a socket that exists and is ours can produce a
  # reported reason.
  defp candidate(path, client_id) do
    cond do
      not File.exists?(path) -> :skip
      not Socket.trusted?(path) -> :skip
      true -> dial(path, client_id)
    end
  end

  defp dial(path, client_id) do
    case :gen_tcp.connect(
           {:local, path},
           0,
           [:binary, packet: :raw, active: false],
           @dial_timeout_ms
         ) do
      {:ok, socket} -> handshake(socket, client_id)
      {:error, _reason} -> {:error, @unavailable}
    end
  end

  defp handshake(socket, client_id) do
    with :ok <- send_frame(socket, Frame.handshake(), %{"v" => 1, "client_id" => client_id}),
         {:ok, _ready} <- await_ready(socket, @max_frames) do
      {:ok, %{socket: socket, next_nonce: 1, pid: os_pid()}}
    else
      {:error, reason} ->
        :gen_tcp.close(socket)
        {:error, reason}
    end
  end

  defp await_ready(_socket, 0), do: {:error, "Discord did not complete the handshake"}

  defp await_ready(socket, attempts) do
    case recv_frame(socket) do
      {:ok, {opcode, payload}} when opcode == 1 ->
        cond do
          payload["evt"] == "READY" -> {:ok, payload}
          true -> await_ready(socket, attempts - 1)
        end

      {:ok, {2, payload}} ->
        {:error, close_message(payload)}

      {:ok, {3, payload}} ->
        with :ok <- send_frame(socket, Frame.pong(), payload),
             do: await_ready(socket, attempts - 1)

      {:ok, {_opcode, _payload}} ->
        await_ready(socket, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- waiting for the acknowledgement --------------------------------------

  defp await_ack(_socket, _nonce, 0), do: {:error, "Discord did not acknowledge the command"}

  defp await_ack(socket, nonce, attempts) do
    case recv_frame(socket) do
      {:ok, {1, %{"evt" => "ERROR"} = payload}} ->
        {:error, error_message(payload)}

      {:ok, {_opcode, %{"nonce" => ^nonce}}} ->
        :ok

      {:ok, {3, payload}} ->
        with :ok <- send_frame(socket, Frame.pong(), payload),
             do: await_ack(socket, nonce, attempts - 1)

      {:ok, {_opcode, _payload}} ->
        await_ack(socket, nonce, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- reading --------------------------------------------------------------

  defp decode_header(socket, <<_opcode::little-32, len::little-32>> = header) do
    cond do
      len > Frame.max_payload() -> {:error, :too_large}
      len == 0 -> Frame.decode(header, "")
      true -> read_body(socket, header, len)
    end
  end

  defp decode_header(_socket, _header), do: {:error, :malformed}

  # `:gen_tcp.recv/3` blocks until it has exactly `len` bytes, so a frame split
  # across packets reassembles here with no buffering of our own.
  defp read_body(socket, header, len) do
    case :gen_tcp.recv(socket, len, @timeout_ms) do
      {:ok, body} -> Frame.decode(header, body)
      {:error, reason} -> {:error, reason}
    end
  end

  # --- framing helpers ------------------------------------------------------

  defp send_frame(socket, opcode, payload) do
    case Frame.encode(opcode, payload) do
      {:ok, bytes} -> :gen_tcp.send(socket, bytes)
      {:error, :too_large} -> {:error, :too_large}
    end
  end

  # The spike measured these exactly: an invalid client id closes with code 4000
  # and the message below, which is the one diagnostics a misconfigured
  # `discord_client_id` produces.
  defp close_message(%{"message" => message}) when is_binary(message), do: message
  defp close_message(_payload), do: @unavailable

  defp error_message(%{"data" => %{"message" => message}}) when is_binary(message), do: message
  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(_payload), do: "Discord rejected the command"

  # `System.pid/0` returns a string; the protocol wants an integer.
  defp os_pid, do: System.pid() |> String.to_integer()
end
