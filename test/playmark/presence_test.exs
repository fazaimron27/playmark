defmodule Playmark.PresenceTest do
  use ExUnit.Case, async: false

  alias Playmark.Presence

  @card %{
    title: "Segments, 403s, and the avformat demuxer",
    author: "Some Channel",
    url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    video_id: "dQw4w9WgXcQ"
  }

  # Stands in for Playmark.Presence.Client. Records every call, and can be told
  # to fail so the reconnect path is exercisable without a Discord install.
  defmodule TestClient do
    def connect(_client_id) do
      test_pid = Application.get_env(:playmark, :presence_test_pid)
      send(test_pid, {:client, :connect})

      case Application.get_env(:playmark, :presence_test_connect) do
        :fail -> {:error, "Discord unavailable"}
        _ok -> {:ok, %{socket: :test_socket, next_nonce: 1, pid: 1}}
      end
    end

    def set_activity(conn, activity) do
      send(Application.get_env(:playmark, :presence_test_pid), {:client, :set_activity, activity})

      case Application.get_env(:playmark, :presence_test_write) do
        :fail -> {:error, "closed"}
        _ok -> {:ok, conn}
      end
    end

    def clear(conn) do
      send(Application.get_env(:playmark, :presence_test_pid), {:client, :clear})
      {:ok, conn}
    end

    def close(_conn) do
      send(Application.get_env(:playmark, :presence_test_pid), {:client, :close})
      :ok
    end
  end

  setup do
    Application.put_env(:playmark, :presence_client_impl, TestClient)
    Application.put_env(:playmark, :presence_test_pid, self())
    Application.put_env(:playmark, :presence_test_connect, :ok)

    on_exit(fn ->
      Application.delete_env(:playmark, :presence_client_impl)
      Application.delete_env(:playmark, :presence_test_pid)
      Application.delete_env(:playmark, :presence_test_connect)
      Application.delete_env(:playmark, :presence_test_write)
      Application.delete_env(:playmark, :discord_presence)
      Application.delete_env(:playmark, :discord_client_id)
    end)

    :ok
  end

  # The application's own supervised instance already owns the name
  # `Playmark.Presence` — parked, because `discord_presence` is unset — so these
  # tests start their own instance under no name at all, and address it through
  # the public API's `server` argument. That way the real casts are what is
  # exercised. Without `name: nil` the start would collide with the parked one.
  defp start(opts \\ []) do
    opts =
      Keyword.merge(
        [
          name: nil,
          enabled: true,
          client_id: "12345",
          refresh_ms: 60,
          backoff_min_ms: 5,
          backoff_max_ms: 20
        ],
        opts
      )

    start_supervised!({Presence, opts})
  end

  defp set_playing(pid, card), do: Presence.set_playing(card, pid)
  defp anchor(pid, position_ms, duration_ms), do: Presence.anchor(position_ms, duration_ms, pid)
  defp clear(pid), do: Presence.clear(pid)

  defp flush_presence do
    receive do
      {:presence_unavailable} -> flush_presence()
      {:presence_status, _status} -> flush_presence()
      {:client, _call} -> flush_presence()
    after
      0 -> :ok
    end
  end

  test "publishes nothing while disabled" do
    pid = start(enabled: false)

    set_playing(pid, @card)

    refute_receive {:client, _call}, 50
    assert Process.alive?(pid)
  end

  # The four tests below cover the badge's input, which is separate from the
  # footer report: `{:presence_status, status}` is sent on *every* transition so
  # the now-playing strip can follow it, while `{:presence_unavailable}` stays
  # gated to once per session.

  test "reports :active to the subscriber when the card is published" do
    pid = start()

    set_playing(pid, @card)

    assert_receive {:presence_status, :active}, 500
  end

  test "reports :active when a repeated set is skipped" do
    # The second set inside the refresh window takes the skip in `publish/1` and
    # never reaches `do_publish` — but the card is live on Discord either way, so
    # the badge belongs lit. Reporting only from `do_publish` would leave a
    # replayed video showing no badge at all.
    pid = start(refresh_ms: 60_000)
    set_playing(pid, @card)
    assert_receive {:presence_status, :active}, 500

    flush_presence()
    set_playing(pid, @card)

    assert_receive {:presence_status, :active}, 500
  end

  test "reports :unavailable on every failure, not only the first" do
    # The footer message is gated; this one deliberately is not. A badge that
    # learned about failure once per session would sit dark for every play after
    # the first while Discord is down.
    Application.put_env(:playmark, :presence_test_connect, :fail)
    pid = start()

    set_playing(pid, @card)
    assert_receive {:presence_status, :unavailable}, 500

    flush_presence()
    set_playing(pid, @card)

    assert_receive {:presence_status, :unavailable}, 500
  end

  test "reports :off to the subscriber when disabled" do
    # The parked instance already holds the subscriber the cast carried, so the
    # TUI never has to read `discord_presence` itself — which is what keeps a
    # default install from showing a badge it cannot justify.
    pid = start(enabled: false)

    set_playing(pid, @card)

    assert_receive {:presence_status, :off}, 500
    refute_receive {:client, _call}, 50
  end

  test "publishes the card on set" do
    pid = start()
    set_playing(pid, @card)

    assert_receive {:client, :connect}, 500
    assert_receive {:client, :set_activity, activity}, 500
    assert activity["details"] == "Segments, 403s, and the avformat demuxer"
    assert is_integer(activity["timestamps"]["start"])
    refute Map.has_key?(activity["timestamps"], "end")
  end

  test "a repeated set for the same video does not republish" do
    # The window is wide here on purpose: the point is the identity comparison,
    # not the keepalive. `start_ms` is recomputed from the clock on each call,
    # so a key that included it would republish and fail this test.
    pid = start(refresh_ms: 60_000)
    set_playing(pid, @card)
    assert_receive {:client, :set_activity, _first}, 500

    set_playing(pid, @card)

    refute_receive {:client, :set_activity, _second}, 100
  end

  test "re-anchors the countdown from the first position report" do
    pid = start(refresh_ms: 60_000)
    set_playing(pid, @card)
    assert_receive {:client, :set_activity, _first}, 500

    anchor(pid, 30_000, 300_000)

    assert_receive {:client, :set_activity, activity}, 500
    assert activity["timestamps"]["end"] - activity["timestamps"]["start"] == 300_000
  end

  test "a re-anchor at a new position republishes, moving the bar" do
    # A seek. Same video, new position: the bar only moves if this write goes
    # out, and the key now carries the anchor, so it does.
    pid = start(refresh_ms: 60_000)
    set_playing(pid, @card)
    assert_receive {:client, :set_activity, _first}, 500

    anchor(pid, 30_000, 300_000)
    assert_receive {:client, :set_activity, anchored}, 500

    anchor(pid, 600_000, 300_000)

    assert_receive {:client, :set_activity, sought}, 500

    # `start_ms` is `now - position`, so a later position is an earlier start.
    # The difference here is ten minutes, which no millisecond of jitter hides.
    assert sought["timestamps"]["start"] < anchored["timestamps"]["start"]
    assert sought["timestamps"]["end"] - sought["timestamps"]["start"] == 300_000
  end

  test "a re-anchor displaces the keepalive rather than adding a write" do
    pid = start(refresh_ms: 60_000)
    set_playing(pid, @card)
    assert_receive {:client, :set_activity, _first}, 500

    anchor(pid, 600_000, 300_000)
    assert_receive {:client, :set_activity, _sought}, 500

    # One write for the seek. `do_publish/2` re-arms the refresh timer after
    # every successful write, so the seek has taken the keepalive's slot rather
    # than racing it.
    refute_receive {:client, :set_activity, _extra}, 100
  end

  test "a different video republishes even inside the refresh window" do
    pid = start(refresh_ms: 60_000)
    set_playing(pid, @card)
    assert_receive {:client, :set_activity, _first}, 500

    set_playing(pid, %{@card | title: "another video"})

    assert_receive {:client, :set_activity, activity}, 500
    assert activity["details"] == "another video"
  end

  test "ignores an anchor when no card is set" do
    pid = start()

    anchor(pid, 30_000, 300_000)

    refute_receive {:client, :set_activity, _activity}, 50
    assert Process.alive?(pid)
  end

  test "republishes an unchanged card once the refresh window elapses" do
    pid = start(refresh_ms: 40)
    set_playing(pid, @card)
    assert_receive {:client, :set_activity, _first}, 500

    # Discord drops an activity that is not re-sent, so this is the keepalive —
    # and the only write that can discover a socket that died while idle.
    assert_receive {:client, :set_activity, _refresh}, 500
  end

  test "clears the card" do
    pid = start()
    set_playing(pid, @card)
    assert_receive {:client, :set_activity, _first}, 500

    clear(pid)

    assert_receive {:client, :clear}, 500
  end

  test "reports unavailable once per session, and not again while still failing" do
    Application.put_env(:playmark, :presence_test_connect, :fail)
    pid = start()

    set_playing(pid, @card)
    assert_receive {:presence_unavailable}, 500

    # Drain first, so the assertion below is about a *second* report rather
    # than a leftover of the first.
    flush_presence()

    set_playing(pid, @card)
    refute_receive {:presence_unavailable}, 100
    assert Process.alive?(pid)
  end

  test "a successful publish re-arms the once-per-session report" do
    Application.put_env(:playmark, :presence_test_connect, :fail)
    # A wide window keeps the keepalive out of the way, so the only writes here
    # are the ones this test causes.
    pid = start(refresh_ms: 60_000)

    set_playing(pid, @card)
    assert_receive {:presence_unavailable}, 500

    # Recover: the next retry connects, which publishes and clears the flag.
    # Drain first so the assertion below is about a genuinely new connection.
    flush_presence()
    Application.put_env(:playmark, :presence_test_connect, :ok)
    assert_receive {:client, :connect}, 1_000
    assert_receive {:client, :set_activity, _published}, 500
    flush_presence()

    # Break the write, then give it something to write. A second report is only
    # possible because a successful publish cleared the flag.
    Application.put_env(:playmark, :presence_test_write, :fail)
    set_playing(pid, %{@card | title: "another video"})

    assert_receive {:client, :close}, 1_000
    assert_receive {:presence_unavailable}, 1_000
  end

  test "closes and reconnects when a write fails" do
    Application.put_env(:playmark, :presence_test_write, :fail)
    pid = start(refresh_ms: 30)

    set_playing(pid, @card)
    assert_receive {:client, :connect}, 500
    assert_receive {:client, :set_activity, _first}, 500
    # The failed write is the only signal that the socket is dead, so it must
    # both close the connection and schedule another attempt.
    assert_receive {:client, :close}, 500
    assert_receive {:client, :connect}, 1_000
  end
end
