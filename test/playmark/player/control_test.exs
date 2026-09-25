defmodule Playmark.Player.ControlTest do
  use ExUnit.Case, async: true

  alias Playmark.Player.Control

  describe "parse_mpv_line/1" do
    test "parses observed timing and seekability properties" do
      assert Control.parse_mpv_line(
               ~s({"event":"property-change","name":"time-pos","data":12.345})
             ) ==
               {:position, 12_345}

      assert Control.parse_mpv_line(~s({"event":"property-change","name":"duration","data":300})) ==
               {:duration, 300_000}

      assert Control.parse_mpv_line(~s({"event":"property-change","name":"seekable","data":true})) ==
               {:seekable, true}
    end

    test "parses EOF and ignores unrelated or malformed messages" do
      assert Control.parse_mpv_line(~s({"event":"end-file","reason":"eof"})) ==
               {:end_file, "eof"}

      assert Control.parse_mpv_line(~s({"event":"idle"})) == :ignore
      assert Control.parse_mpv_line("not json") == :ignore
    end
  end

  describe "parse_vlc_value/1" do
    test "parses plain and prompt-prefixed non-negative integer responses" do
      assert Control.parse_vlc_value("123\n") == {:ok, 123}
      assert Control.parse_vlc_value("> 456\n") == {:ok, 456}
    end

    test "ignores prompts, errors, and negative values" do
      assert Control.parse_vlc_value("> ") == :ignore
      assert Control.parse_vlc_value("status change: stop") == :ignore
      assert Control.parse_vlc_value("-1") == :ignore
    end
  end

  describe "request_quit/2" do
    setup do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

      {:ok, {_ip, port}} = :inet.sockname(listener)
      {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
      {:ok, server} = :gen_tcp.accept(listener, 1_000)

      on_exit(fn ->
        Enum.each([client, server, listener], &:gen_tcp.close/1)
      end)

      %{client: client, server: server}
    end

    test "writes mpv's JSON IPC quit command", %{client: client, server: server} do
      assert Control.request_quit(:mpv, client) == :ok
      assert {:ok, data} = :gen_tcp.recv(server, 0, 1_000)
      assert data == ~s({"command":["quit"]}\n)
    end

    test "writes VLC's RC shutdown command, which is what actually exits VLC", %{
      client: client,
      server: server
    } do
      assert Control.request_quit(:vlc, client) == :ok
      assert {:ok, data} = :gen_tcp.recv(server, 0, 1_000)
      assert data == "shutdown\n"
    end

    test "is a no-op when there is no socket" do
      assert Control.request_quit(:mpv, nil) == :ok
      assert Control.request_quit(:vlc, nil) == :ok
    end
  end

  # Drives the real receive loop. `args_fun` is handed the control endpoint
  # before Control tries to connect, so the test can stand up a listener on that
  # exact port and make the connect succeed. `sleep` stands in for the player: it
  # is harmless, always present, and exits on its own schedule.
  describe "run/4 control lifecycle" do
    defp run_fake_player(seconds) do
      test_pid = self()
      opts = %{progress: fn event -> send(test_pid, {:progress, event}) end}

      args_fun = fn port ->
        {:ok, listener} =
          :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

        send(test_pid, {:listener, listener})
        [seconds]
      end

      Task.async(fn -> Control.run(:vlc, "sleep", args_fun, opts) end)
    end

    # Collects whatever the player's control socket receives until `pattern`
    # shows up or the budget runs out. VLC is polled, so `get_time` arrives
    # unprompted and has to be read past.
    defp await_command(socket, pattern, deadline_ms, seen \\ "") do
      cond do
        String.contains?(seen, pattern) ->
          {:ok, seen}

        deadline_ms <= 0 ->
          {:error, seen}

        true ->
          case :gen_tcp.recv(socket, 0, 200) do
            {:ok, data} -> await_command(socket, pattern, deadline_ms - 200, seen <> data)
            {:error, :timeout} -> await_command(socket, pattern, deadline_ms - 200, seen)
            {:error, _reason} -> {:error, seen}
          end
      end
    end

    test "reports the control socket as ready once it connects" do
      task = run_fake_player("0.3")

      assert_receive {:progress, {:control, :ready}}, 2_000
      assert Task.await(task, 5_000) == {:ok, :unknown}
    end

    test "a stop request asks the player to quit over its control socket" do
      task = run_fake_player("1")

      assert_receive {:listener, listener}, 2_000
      assert_receive {:progress, {:control, :ready}}, 2_000
      {:ok, server} = :gen_tcp.accept(listener, 1_000)

      send(task.pid, :playmark_stop)

      assert {:ok, seen} = await_command(server, "shutdown\n", 2_000)
      assert seen =~ "shutdown"

      Task.await(task, 5_000)
      :gen_tcp.close(server)
      :gen_tcp.close(listener)
    end

    # Cancelling during preparation used to let the player launch and immediately
    # quit — a window flashing on screen — because the stop only reached the
    # monitor loop, which starts after the port is open. The last thing before
    # opening it is a mailbox check, so a stop that arrived while yt-dlp was still
    # running means the player never starts at all.
    test "a stop that arrived during preparation prevents the launch entirely" do
      test_pid = self()

      opts = %{progress: fn event -> send(test_pid, {:progress, event}) end}

      args_fun = fn _port ->
        send(test_pid, :args_built)
        ["5"]
      end

      task =
        Task.async(fn ->
          # Already in the mailbox before run/4 is called, exactly as a cancel
          # during a blocking System.cmd leaves it.
          send(self(), :playmark_stop)
          Control.run(:vlc, "sleep", args_fun, opts)
        end)

      assert Task.await(task, 2_000) == {:ok, :stopped}
      # No port was opened, so no args were ever built and no control was reported.
      refute_received :args_built
      refute_received {:progress, {:control, _}}
    end
  end
end
