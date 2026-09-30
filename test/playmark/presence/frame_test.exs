defmodule Playmark.Presence.FrameTest do
  use ExUnit.Case, async: true

  alias Playmark.Presence.Frame

  test "round-trips a frame" do
    assert {:ok, bytes} = Frame.encode(Frame.frame(), %{"cmd" => "SET_ACTIVITY"})

    <<header::binary-size(8), body::binary>> = bytes
    assert {:ok, {1, %{"cmd" => "SET_ACTIVITY"}}} = Frame.decode(header, body)
  end

  test "writes the header as opcode then little-endian byte length" do
    assert {:ok, bytes} = Frame.encode(Frame.handshake(), %{"v" => 1})
    body = Jason.encode!(%{"v" => 1})

    assert bytes == <<0::little-32, byte_size(body)::little-32, body::binary>>
  end

  test "returns header and payload as one binary, so a caller writes them in a single send" do
    assert {:ok, bytes} = Frame.encode(Frame.frame(), %{})
    assert is_binary(bytes)
    assert byte_size(bytes) == 8 + byte_size("{}")
  end

  test "refuses to encode a payload above the cap" do
    huge = %{"blob" => String.duplicate("x", Frame.max_payload())}
    assert {:error, :too_large} = Frame.encode(Frame.frame(), huge)
  end

  test "refuses a declared length above the cap without decoding" do
    header = <<1::little-32, Frame.max_payload() + 1::little-32>>
    assert {:error, :too_large} = Frame.decode(header, "anything")
  end

  test "treats a zero-length payload as empty rather than decoding it" do
    assert {:error, :empty} = Frame.decode(<<1::little-32, 0::little-32>>, "")
  end

  test "rejects garbage JSON" do
    body = "not json at all"
    assert {:error, :malformed} = Frame.decode(<<1::little-32, byte_size(body)::little-32>>, body)
  end

  test "rejects a body whose length disagrees with the header" do
    header = <<1::little-32, 99::little-32>>
    assert {:error, :malformed} = Frame.decode(header, "short")
  end

  test "rejects a header that is not eight bytes" do
    assert {:error, :malformed} = Frame.decode(<<1, 2, 3>>, "body")
  end
end
