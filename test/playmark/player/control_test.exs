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

    test "parses the pause property in both directions" do
      assert Control.parse_mpv_line(~s({"event":"property-change","name":"pause","data":true})) ==
               {:pause, true}

      assert Control.parse_mpv_line(~s({"event":"property-change","name":"pause","data":false})) ==
               {:pause, false}
    end
  end

  describe "parse_vlc_state/1" do
    # VLC has no pause *event*: its RC interface is polled, and `status` is the
    # only thing that answers the question. Measured against VLC 3.0.24, whose
    # reply is three lines — the state is the last of them, but the parser keys
    # on content, so line order cannot make it miss.
    test "reads the playing and paused states out of a status reply" do
      assert Control.parse_vlc_state("> ( state playing )") == {:ok, :playing}
      assert Control.parse_vlc_state("( state paused )") == {:ok, :paused}
    end

    test "ignores the other lines a status reply carries" do
      assert Control.parse_vlc_state("( new input: file:///tmp/a.mp4 )") == :ignore
      assert Control.parse_vlc_state("> ( audio volume: 0.0 )") == :ignore
    end

    # Only the two states a pause feature acts on are read. Anything else is
    # left alone: reporting a pause for a state we do not recognise would clear
    # the card of a video that is still playing.
    test "ignores states it was not told to act on" do
      assert Control.parse_vlc_state("( state stopped )") == :ignore
      assert Control.parse_vlc_state("> ") == :ignore
      assert Control.parse_vlc_state("") == :ignore
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

  describe "discontinuity?/3" do
    # A sample is `%{position_ms: position, observed_at: monotonic_ms}`. These are
    # synthetic on purpose: the function compares a prediction against an
    # observation and never touches a player, the same treatment
    # `parse_vlc_state/1` gets.

    test "the first sample is not a discontinuity" do
      # There is nothing to compare against. This is what lets a play anchor
      # without announcing a seek it cannot know about.
      refute Control.discontinuity?(nil, 45_000, 1_000_000)
    end

    test "a natural advance keeps the anchor, however stale the sample" do
      # The case the `anchor: nil` guard in PlaybackActions existed for:
      # `maybe_checkpoint/2` emits one sample per 10s of movement at most, so a
      # sample can be ten seconds old. That is not a jump — it is exactly what
      # the interpolation predicts.
      last = %{position_ms: 45_000, observed_at: 1_000_000}

      refute Control.discontinuity?(last, 55_000, 1_010_000)
    end

    test "a forward jump is a discontinuity" do
      last = %{position_ms: 45_000, observed_at: 1_000_000}

      assert Control.discontinuity?(last, 645_000, 1_005_000)
    end

    test "a backwards jump smaller than the reporting throttle is a discontinuity" do
      # The case that puts this test in Control at all. The positions either side
      # are 45_000 and 40_000 — a 5s backward seek, well under the 10s
      # `checkpoint_due?/2` requires — so `maybe_checkpoint/2` emits no
      # `{:checkpoint, …}` at all. Nothing downstream can recover an event that
      # was never sent.
      last = %{position_ms: 45_000, observed_at: 1_000_000}

      assert Control.discontinuity?(last, 40_000, 1_005_000)
    end

    test "scheduling jitter is not a discontinuity" do
      # The sample landed slightly early and the position sits slightly behind
      # the prediction. Both are inside the tolerance.
      last = %{position_ms: 45_000, observed_at: 1_000_000}

      refute Control.discontinuity?(last, 44_200, 1_000_900)
    end

    test "the tolerance boundary keeps the anchor" do
      last = %{position_ms: 45_000, observed_at: 1_000_000}

      # Exactly 2s off the prediction is still within it — `>` rather than `>=`,
      # so the comparison is "further than the tolerance", not "at least".
      refute Control.discontinuity?(last, 47_000, 1_000_000)
      assert Control.discontinuity?(last, 47_001, 1_000_000)
    end

    test "an out-of-order observation is not a jump forwards" do
      # `max(elapsed, 0)`: a sample stamped before its predecessor must not push
      # the prediction past the position and fire.
      last = %{position_ms: 45_000, observed_at: 1_010_000}

      refute Control.discontinuity?(last, 45_000, 1_000_000)
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

    # mpv's control endpoint is a Unix socket rather than a port, so the fake
    # player binds the exact path Control was handed. Same shape as
    # run_fake_player/1 otherwise: `sleep` stands in for mpv.
    defp run_fake_mpv_player(seconds) do
      test_pid = self()
      opts = %{progress: fn event -> send(test_pid, {:progress, event}) end}

      args_fun = fn path ->
        {:ok, listener} =
          :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false])

        send(test_pid, {:listener, listener})
        [seconds]
      end

      Task.async(fn -> Control.run(:mpv, "sleep", args_fun, opts) end)
    end

    defp send_line(socket, line), do: :gen_tcp.send(socket, line <> "\n")

    defp paused_property(paused?),
      do: ~s({"event":"property-change","name":"pause","data":#{paused?}})

    test "subscribes to mpv's pause property along with the timing ones" do
      task = run_fake_mpv_player("0.5")

      assert_receive {:listener, listener}, 2_000
      assert_receive {:progress, {:control, :ready}}, 2_000
      {:ok, server} = :gen_tcp.accept(listener, 1_000)

      # Without this subscription there is no pause signal at all: mpv sends
      # nothing unprompted, so the card would stay up through a pause.
      assert {:ok, seen} = await_command(server, ~s("pause"), 2_000)
      assert seen =~ ~s(["observe_property",4,"pause"])

      Task.await(task, 5_000)
      :gen_tcp.close(server)
      :gen_tcp.close(listener)
    end

    test "reports mpv's pause and resume as they happen" do
      task = run_fake_mpv_player("1")

      assert_receive {:listener, listener}, 2_000
      assert_receive {:progress, {:control, :ready}}, 2_000
      {:ok, server} = :gen_tcp.accept(listener, 1_000)

      send_line(server, paused_property(true))
      assert_receive {:progress, {:paused, true}}, 1_000

      send_line(server, paused_property(false))
      assert_receive {:progress, {:paused, false}}, 1_000

      Task.await(task, 5_000)
      :gen_tcp.close(server)
      :gen_tcp.close(listener)
    end

    # mpv sends the property's *current value* the moment it is subscribed to,
    # before any playback stage. Reporting that observation would announce a
    # resume on every play, clearing and republishing a card that was never
    # paused.
    test "mpv's initial pause observation is not reported as a resume" do
      task = run_fake_mpv_player("0.5")

      assert_receive {:listener, listener}, 2_000
      assert_receive {:progress, {:control, :ready}}, 2_000
      {:ok, server} = :gen_tcp.accept(listener, 1_000)

      send_line(server, paused_property(false))
      refute_receive {:progress, {:paused, _}}, 300

      Task.await(task, 5_000)
      :gen_tcp.close(server)
      :gen_tcp.close(listener)
    end

    # Resuming republishes the card, and the bar it draws needs a fresh anchor —
    # the position report that carries it is the one this forces, because mpv
    # sends nothing of its own while the position is not moving.
    test "resuming re-reports the position so the card can re-anchor" do
      task = run_fake_mpv_player("1")

      assert_receive {:listener, listener}, 2_000
      assert_receive {:progress, {:control, :ready}}, 2_000
      {:ok, server} = :gen_tcp.accept(listener, 1_000)

      send_line(server, ~s({"event":"property-change","name":"seekable","data":true}))
      send_line(server, ~s({"event":"property-change","name":"duration","data":300}))
      send_line(server, ~s({"event":"property-change","name":"time-pos","data":45}))

      # The ordinary throttled checkpoint, which consumes the only copy of this
      # pair so the assertion further down cannot match it again.
      assert_receive {:progress, {:checkpoint, 45_000, 300_000}}, 1_000

      send_line(server, paused_property(true))
      assert_receive {:progress, {:paused, true}}, 1_000
      # Pausing checkpoints nothing. It is about to clear the card, so a fresher
      # position there would be written for nobody.
      refute_receive {:progress, {:checkpoint, _, _}}, 300

      # The resume is reported *before* the position it forces. The other order
      # would be silently wrong end to end: republishing the card resets the
      # anchor, so a position that arrived first would be discarded and the bar
      # would stay blank until the next throttled checkpoint.
      send_line(server, paused_property(false))
      assert_receive {:progress, {:paused, false}}, 1_000
      assert_receive {:progress, {:checkpoint, 45_000, 300_000}}, 1_000

      Task.await(task, 5_000)
      :gen_tcp.close(server)
      :gen_tcp.close(listener)
    end

    # `wait_ms` is the budget for the *first* command of the cycle, which is the
    # one that waits out Control's poll interval; the rest of a cycle follows
    # immediately.
    defp answer_vlc_poll(socket, time, length, state, wait_ms \\ 2_000) do
      assert {:ok, _} = await_command(socket, "get_time\n", wait_ms)
      :gen_tcp.send(socket, time <> "\n")

      assert {:ok, _} = await_command(socket, "get_length\n", 2_000)
      :gen_tcp.send(socket, length <> "\n")

      assert {:ok, _} = await_command(socket, "status\n", 2_000)
      :gen_tcp.send(socket, state)
    end

    # VLC has no pause event, so the state rides along with the poll that
    # already fetches the position — one extra command in a cycle that is
    # happening anyway.
    test "reports a pause when VLC's polled status says paused" do
      task = run_fake_player("2")

      assert_receive {:listener, listener}, 2_000
      assert_receive {:progress, {:control, :ready}}, 2_000
      {:ok, server} = :gen_tcp.accept(listener, 1_000)

      answer_vlc_poll(server, "45", "300", """
      ( new input: file:///tmp/a.mp4 )
      ( audio volume: 0.0 )
      ( state paused )
      """)

      assert_receive {:progress, {:paused, true}}, 2_000

      Task.await(task, 5_000)
      :gen_tcp.close(server)
      :gen_tcp.close(listener)
    end

    # The same rule as mpv's: the first poll reports the state playback is
    # already in, and reporting it would announce a resume on every play.
    test "VLC's first poll reporting playing is not a resume" do
      task = run_fake_player("1")

      assert_receive {:listener, listener}, 2_000
      assert_receive {:progress, {:control, :ready}}, 2_000
      {:ok, server} = :gen_tcp.accept(listener, 1_000)

      answer_vlc_poll(server, "45", "300", "( state playing )\n")
      refute_receive {:progress, {:paused, _}}, 500

      Task.await(task, 5_000)
      :gen_tcp.close(server)
      :gen_tcp.close(listener)
    end

    # A VLC pause is only ever noticed on a poll, and so is a resume — which is
    # the direction that has to carry a forced position, because the card
    # republished on resume has no anchor of its own.
    test "a resumed VLC reports the resume and then the position that re-anchors it" do
      task = run_fake_player("6")

      assert_receive {:listener, listener}, 2_000
      assert_receive {:progress, {:control, :ready}}, 2_000
      {:ok, server} = :gen_tcp.accept(listener, 1_000)

      answer_vlc_poll(server, "45", "300", "( state paused )\n")
      assert_receive {:progress, {:paused, true}}, 2_000

      # The wait is real: the poll interval is five seconds and this test does
      # not get to shorten it.
      answer_vlc_poll(server, "46", "300", "( state playing )\n", 7_000)
      assert_receive {:progress, {:paused, false}}, 2_000
      assert_receive {:progress, {:checkpoint, 46_000, 300_000}}, 1_000

      Task.await(task, 5_000)
      :gen_tcp.close(server)
      :gen_tcp.close(listener)
    end

    test "VLC's pause is reported on the change, not again on every poll" do
      task = run_fake_player("6")

      assert_receive {:listener, listener}, 2_000
      assert_receive {:progress, {:control, :ready}}, 2_000
      {:ok, server} = :gen_tcp.accept(listener, 1_000)

      answer_vlc_poll(server, "45", "300", "( state paused )\n")
      assert_receive {:progress, {:paused, true}}, 2_000

      # The next poll answers the same thing. Reporting it again would re-clear
      # a card that is already clear, every five seconds, for as long as the
      # video stays paused.
      answer_vlc_poll(server, "45", "300", "( state paused )\n", 7_000)
      refute_receive {:progress, {:paused, _}}, 300

      Task.await(task, 5_000)
      :gen_tcp.close(server)
      :gen_tcp.close(listener)
    end
  end
end
