defmodule Playmark.Presence.Frame do
  @moduledoc """
  Encodes and decodes Discord IPC frames.

  A frame is an 8-byte little-endian header — the opcode, then the payload's
  byte length — followed by a JSON payload. `encode/2` returns header and
  payload as **one** binary because the protocol requires them in a single
  write; splitting the write is what makes a reader see a partial frame.

  Pure, and deliberately so: the wire format is the one part of this subsystem
  that a bug would be hardest to see, and the only part that can be pinned
  without a socket. The reader that copes with a frame split across packets
  lives in `Playmark.Presence.Client`, next to the `:gen_tcp.recv/3` calls that
  make it possible.

  ## Opcodes

  `0` handshake, `1` frame, `2` close, `3` ping, `4` pong. A close frame's
  payload carries a `code` and `message`, e.g. `4000` / `Invalid Client ID`.
  """

  # Discord's own frame ceiling. A corrupt or hostile length must not drive a
  # large allocation, so it is enforced on both sides of the wire.
  @max_payload 1_048_576

  @opcode_handshake 0
  @opcode_frame 1
  @opcode_close 2
  @opcode_ping 3
  @opcode_pong 4

  @doc "Opcode 0 — the handshake."
  def handshake, do: @opcode_handshake

  @doc "Opcode 1 — an ordinary command or dispatch."
  def frame, do: @opcode_frame

  @doc "Opcode 2 — Discord is closing the connection."
  def close, do: @opcode_close

  @doc "Opcode 3 — a ping from Discord."
  def ping, do: @opcode_ping

  @doc "Opcode 4 — replies to a ping."
  def pong, do: @opcode_pong

  @doc "The largest payload Discord accepts, in bytes."
  def max_payload, do: @max_payload

  @doc """
  Frames `payload` under `opcode`, header and body together.

  Returns `{:error, :too_large}` above `max_payload/0` rather than sending a
  frame Discord would truncate.
  """
  def encode(opcode, payload) when is_integer(opcode) and is_map(payload) do
    body = Jason.encode!(payload)

    if byte_size(body) > @max_payload,
      do: {:error, :too_large},
      else: {:ok, <<opcode::little-32, byte_size(body)::little-32, body::binary>>}
  end

  @doc """
  Decodes one frame from its 8-byte `header` and its `body`.

  Errors are `:too_large` (declared length above the cap), `:empty` (a
  zero-length payload, which Discord never sends and which is safer to reject
  than to turn into a `nil` payload), and `:malformed` (header, length, or
  JSON). Every error is a connection failure to the caller — none is fatal.
  """
  # The opcode is bound from the header, not re-derived from the body — the
  # header is the only place it exists.
  def decode(<<opcode::little-32, len::little-32>>, body) when is_binary(body) do
    cond do
      len > @max_payload -> {:error, :too_large}
      len != byte_size(body) -> {:error, :malformed}
      len == 0 -> {:error, :empty}
      true -> decode_body(opcode, body)
    end
  end

  def decode(_header, _body), do: {:error, :malformed}

  defp decode_body(opcode, body) do
    case Jason.decode(body) do
      {:ok, payload} -> {:ok, {opcode, payload}}
      {:error, _error} -> {:error, :malformed}
    end
  end
end
