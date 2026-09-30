defmodule Playmark.Presence.ClientTest do
  # Not async: it stands up real Unix sockets, and the paths are derived from
  # System.unique_integer/1 rather than from the test pid, so nothing relies on
  # process isolation.
  use ExUnit.Case, async: false

  alias Playmark.Presence.{Client, Frame}

  setup do
    path =
      Path.join(System.tmp_dir!(), "playmark-client-#{System.unique_integer([:positive])}.sock")

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, path}])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    %{path: path, listener: listener}
  end

  # --- the wire, read and written for real ----------------------------------

  defp recv_frame(socket) do
    {:ok, <<opcode::little-32, len::little-32>>} = :gen_tcp.recv(socket, 8, 1_000)
    {:ok, body} = :gen_tcp.recv(socket, len, 1_000)
    {opcode, Jason.decode!(body)}
  end

  defp send_frame(socket, opcode, payload) do
    body = Jason.encode!(payload)
    :ok = :gen_tcp.send(socket, <<opcode::little-32, byte_size(body)::little-32, body::binary>>)
  end

  # Runs a real connect against the listener and answers READY, so a test can
  # get to a connected client without a Discord install.
  #
  # The connect runs in a task so this process is free to accept, and the socket
  # is handed back before that task exits: a `:gen_tcp` socket is closed when
  # its owning process dies, so without the transfer every later assertion would
  # read `{:error, :closed}`. That is the same rule that forces
  # `Playmark.Presence` to dial from its own process rather than a spawned task.
  defp connect(listener, path, client_id \\ "12345") do
    parent = self()

    task =
      Task.async(fn ->
        result = Client.connect(client_id, [path])

        with {:ok, conn} <- result do
          :ok = :gen_tcp.controlling_process(conn.socket, parent)
        end

        result
      end)

    {:ok, server} = :gen_tcp.accept(listener, 1_000)

    assert {0, %{"v" => 1, "client_id" => ^client_id}} = recv_frame(server)
    send_frame(server, 1, %{"cmd" => "DISPATCH", "evt" => "READY", "data" => %{"v" => 1}})

    assert {:ok, conn} = Task.await(task, 2_000)
    {conn, server}
  end

  # --- handshake ------------------------------------------------------------

  test "writes the handshake frame and waits for READY", %{listener: listener, path: path} do
    {conn, _server} = connect(listener, path)
    Client.close(conn)
  end

  test "surfaces Discord's close message when the client id is rejected", %{
    listener: listener,
    path: path
  } do
    task = Task.async(fn -> Client.connect("bogus", [path]) end)
    {:ok, server} = :gen_tcp.accept(listener, 1_000)

    assert {0, %{"client_id" => "bogus"}} = recv_frame(server)
    send_frame(server, 2, %{"code" => 4000, "message" => "Invalid Client ID"})

    assert {:error, "Invalid Client ID"} = Task.await(task, 2_000)
  end

  test "answers a ping and keeps waiting for READY", %{listener: listener, path: path} do
    task = Task.async(fn -> Client.connect("12345", [path]) end)
    {:ok, server} = :gen_tcp.accept(listener, 1_000)

    assert {0, _handshake} = recv_frame(server)
    send_frame(server, 3, %{"ping" => "pong"})
    assert {4, %{"ping" => "pong"}} = recv_frame(server)
    send_frame(server, 1, %{"cmd" => "DISPATCH", "evt" => "READY"})

    assert {:ok, conn} = Task.await(task, 2_000)
    Client.close(conn)
  end

  # --- SET_ACTIVITY ---------------------------------------------------------

  test "sends our pid as an integer and correlates the reply by nonce", %{
    listener: listener,
    path: path
  } do
    {conn, server} = connect(listener, path)
    task = Task.async(fn -> Client.set_activity(conn, %{"details" => "hi"}) end)

    assert {1, %{"cmd" => "SET_ACTIVITY", "nonce" => nonce, "args" => args}} = recv_frame(server)
    assert args["pid"] == String.to_integer(System.pid())
    assert args["activity"] == %{"details" => "hi"}

    send_frame(server, 1, %{"cmd" => "SET_ACTIVITY", "nonce" => nonce, "data" => %{}})

    assert {:ok, %{next_nonce: 2}} = Task.await(task, 2_000)
    Client.close(conn)
  end

  test "advances the nonce across calls", %{listener: listener, path: path} do
    {conn, server} = connect(listener, path)

    # The connection has to be threaded through, not reused: a `for` body
    # rebinding `conn` does not escape the comprehension, so a second call would
    # resend nonce "1" and the assertion on "2" would never be reached.
    conn =
      Enum.reduce(["1", "2"], conn, fn expected, conn ->
        task = Task.async(fn -> Client.set_activity(conn, %{"details" => expected}) end)
        assert {1, %{"nonce" => ^expected}} = recv_frame(server)
        send_frame(server, 1, %{"nonce" => expected})
        assert {:ok, conn} = Task.await(task, 2_000)
        conn
      end)

    Client.close(conn)
  end

  test "ignores an unrelated frame and waits for the matching nonce", %{
    listener: listener,
    path: path
  } do
    {conn, server} = connect(listener, path)
    task = Task.async(fn -> Client.set_activity(conn, %{"details" => "hi"}) end)

    assert {1, %{"nonce" => nonce}} = recv_frame(server)
    send_frame(server, 1, %{"cmd" => "DISPATCH", "evt" => "SOMETHING_ELSE", "nonce" => "999"})
    send_frame(server, 1, %{"nonce" => nonce})

    assert {:ok, _conn} = Task.await(task, 2_000)
    Client.close(conn)
  end

  test "treats an ERROR frame as a failure", %{listener: listener, path: path} do
    {conn, server} = connect(listener, path)
    task = Task.async(fn -> Client.set_activity(conn, %{"details" => "hi"}) end)

    assert {1, %{"nonce" => _nonce}} = recv_frame(server)

    send_frame(server, 1, %{
      "cmd" => "DISPATCH",
      "evt" => "ERROR",
      "data" => %{"message" => "Invalid activity"}
    })

    assert {:error, "Invalid activity"} = Task.await(task, 2_000)
    Client.close(conn)
  end

  test "clears by sending a null activity", %{listener: listener, path: path} do
    {conn, server} = connect(listener, path)
    task = Task.async(fn -> Client.clear(conn) end)

    assert {1, %{"nonce" => nonce, "args" => %{"activity" => nil}}} = recv_frame(server)
    send_frame(server, 1, %{"nonce" => nonce})

    assert {:ok, _conn} = Task.await(task, 2_000)
    Client.close(conn)
  end

  # --- the reader -----------------------------------------------------------

  test "reassembles a reply split across two packets", %{listener: listener, path: path} do
    {conn, server} = connect(listener, path)
    task = Task.async(fn -> Client.set_activity(conn, %{"details" => "hi"}) end)

    assert {1, %{"nonce" => nonce}} = recv_frame(server)
    body = Jason.encode!(%{"cmd" => "SET_ACTIVITY", "nonce" => nonce})

    # Header and body in separate writes, with a pause so they cannot coalesce
    # into one packet — the case a naive reader loses.
    :ok = :gen_tcp.send(server, <<1::little-32>>)
    Process.sleep(30)
    :ok = :gen_tcp.send(server, <<byte_size(body)::little-32, body::binary>>)

    assert {:ok, _conn} = Task.await(task, 2_000)
    Client.close(conn)
  end

  test "rejects a frame whose declared length exceeds the cap", %{listener: listener, path: path} do
    {conn, server} = connect(listener, path)
    task = Task.async(fn -> Client.set_activity(conn, %{"details" => "hi"}) end)

    assert {1, %{"nonce" => _nonce}} = recv_frame(server)
    :ok = :gen_tcp.send(server, <<1::little-32, Frame.max_payload() + 1::little-32>>)

    assert {:error, :too_large} = Task.await(task, 2_000)
    Client.close(conn)
  end

  # --- candidate selection --------------------------------------------------

  test "skips candidates that do not exist" do
    missing =
      Path.join(System.tmp_dir!(), "playmark-missing-#{System.unique_integer([:positive])}.sock")

    assert {:error, "Discord unavailable"} = Client.connect("12345", [missing])
  end

  test "returns unavailable when there are no candidates at all" do
    assert {:error, "Discord unavailable"} = Client.connect("12345", [])
  end

  test "names no path in the error, so a planted socket is never advertised" do
    path =
      Path.join(
        System.tmp_dir!(),
        "playmark-notasocket-#{System.unique_integer([:positive])}.sock"
      )

    File.write!(path, "")
    on_exit(fn -> File.rm(path) end)

    assert {:error, "Discord unavailable"} = Client.connect("12345", [path])
  end
end
