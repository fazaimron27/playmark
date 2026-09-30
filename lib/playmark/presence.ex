defmodule Playmark.Presence do
  @moduledoc """
  Publishes a Discord Rich Presence card for the video being watched.

  One supervised process owns the socket, the keepalive, the reconnect backoff,
  and the republish dedup. The TUI pushes to it through `Playmark.TUI.Impl`'s
  `:presence_impl` seam and never reads its state; it reaches Discord only
  through `Playmark.Presence.Client`.

  ## Opt-in, and parked when off

  The process always starts; whether it *does* anything is governed by the
  `discord_presence` setting. When that is false it holds no socket, arms no
  timer, and every cast is a no-op. A config change takes effect on restart,
  which is how every other playmark setting behaves.

  ## Why a process, rather than the playback task

  `Playmark.Player.Control` owns its socket alongside the player, which works
  because its lifetime *is* the play's. Presence cannot: the keepalive must
  outlive any single play, and clearing must work when no play is running at all
  (app exit, a failed launch, a cancelled preparation). Owning the socket in the
  playback task would mean reasoning about three lifecycle interactions — take,
  cancel, stop — against the one process here, which has none of them.

  ## No shutdown hook

  There is no `terminate/2` closing the socket, and that is not an omission. The
  dial in `Client.connect/2` is made *from this process*, so this process owns
  the socket, and a `:gen_tcp` socket is closed when its owner dies — verified,
  not assumed. Supervisor shutdown and a crash-restart both therefore drop the
  connection without any hook; adding one would be machinery that claims to be
  load-bearing while doing nothing. The one thing it would cost is not obvious:
  a hook that reaches the client through the seam can run after a test's
  application env is torn down, and would then call the *real* client with a
  stub's connection.

  ## Keepalive

  The card is re-sent every 15 seconds, unchanged, for as long as it should be
  displayed. Discord drops an activity that is not re-sent. This is also what
  makes a dead socket noticeable: there is no background reader, so a failed
  write is the only signal, and an idle card would otherwise never produce one.

  A publish is skipped only when the card is unchanged **and** a connection is
  up **and** the last successful publish was inside the refresh window. The dedup
  key is the card's identity — title, channel, URL, video id — plus whether it
  has been anchored. It deliberately excludes the anchor's own `start_ms`, which
  is recomputed from the clock on every report: including it would make the key
  different every time and put the skip permanently out of reach.

  ## Failures

  Best-effort, always: nothing here may raise into the TUI, block a play, or
  delay a keystroke. Discord being unreachable is reported to the caller **once
  per session** as `{:presence_unavailable}` and then left alone.

  Every transition reaches the caller rather than only the failures, as
  `{:presence_status, status}` — `:active` when the card is live (or was skipped
  as already live), `:unavailable` on any failure, and `:off` when the process is
  parked. The TUI draws the now-playing badge from it, and the two messages are
  deliberately different frequencies: a badge that learned of a failure once per
  session would sit dark for every play after the first while Discord was down,
  whereas the footer is only worth telling a user once. `:off` in particular is
  why the TUI never reads `discord_presence`: the parked clause already holds the
  subscriber the cast carried.

  The flag re-arms on a successful **publish**, not merely on a successful
  connect. That distinction matters when a socket opens but writes keep failing:
  re-arming on connect would report again on every reconnect cycle, and the
  backoff would turn that into a status line re-firing several times a second
  for as long as the fault lasted. Re-arming on a publish means the report is
  about presence actually working again, which is also the only claim worth
  making to the user.

  Both failure paths report: a connection that cannot be made, and a write on a
  connection that has apparently died. The second is the only way a mid-session
  Discord exit is noticed at all — there is no background reader — and without it
  a write failure that was never followed by a failed reconnect would be
  completely silent.

  There is no logging — the TUI owns the terminal, so an ordinary log line would
  corrupt the display. Diagnostics live behind `mix playmark.debug --presence`.
  """

  use GenServer

  alias Playmark.Presence.{Activity, Client}

  # The application registered by the project owner. Shipped as a default so a
  # user does not have to visit the Developer Portal before the card works; it
  # is public in the repository and overridable.
  @default_client_id "1554861700455334040"

  @default_refresh_ms 15_000
  @default_backoff_min_ms 1_000
  @default_backoff_max_ms 30_000

  @doc "Re-sent unconditionally on this interval; see the moduledoc."
  def refresh_ms, do: @default_refresh_ms

  @type card :: %{
          title: String.t(),
          author: String.t() | nil,
          url: String.t(),
          video_id: String.t() | nil,
          start_ms: integer() | nil,
          duration_ms: integer() | nil
        }

  # --- public API ------------------------------------------------------------

  @doc """
  Announces `card` — `%{title:, author:, url:, video_id:}` — as the activity.

  A cast, so it never blocks a keystroke. `self/0` is captured because the
  once-per-session failure report is sent back to whoever asked.
  """
  def set_playing(card, server \\ __MODULE__) when is_map(card) do
    GenServer.cast(server, {:set_playing, card, self()})
  end

  @doc """
  Re-anchors the countdown from a reported position and duration.

  Ignored when no card is set: a card always originates from `set_playing/1`, so
  a takeover or a queue advance is a fresh set rather than a transition here.
  """
  def anchor(position_ms, duration_ms, server \\ __MODULE__)
      when is_integer(position_ms) and is_integer(duration_ms) do
    GenServer.cast(server, {:anchor, position_ms, duration_ms})
  end

  @doc "Clears the card."
  def clear(server \\ __MODULE__), do: GenServer.cast(server, :clear)

  # --- lifecycle -------------------------------------------------------------

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      enabled: Keyword.get_lazy(opts, :enabled, &enabled?/0),
      client_id: Keyword.get_lazy(opts, :client_id, &client_id/0),
      conn: nil,
      card: nil,
      published: nil,
      published_at: nil,
      subscriber: nil,
      reported_failure: false,
      retry_ref: nil,
      refresh_ref: nil,
      backoff_ms: Keyword.get(opts, :backoff_min_ms, @default_backoff_min_ms),
      timings: %{
        refresh_ms: Keyword.get(opts, :refresh_ms, @default_refresh_ms),
        backoff_min_ms: Keyword.get(opts, :backoff_min_ms, @default_backoff_min_ms),
        backoff_max_ms: Keyword.get(opts, :backoff_max_ms, @default_backoff_max_ms)
      }
    }

    {:ok, state}
  end

  # --- casts -----------------------------------------------------------------

  @impl true
  def handle_cast({:set_playing, _card, subscriber}, %{enabled: false} = state) do
    # The badge is the only thing the TUI hears about a parked process, and it
    # needs to: with presence off there is no card to report on, and a badge that
    # simply never arrived would be indistinguishable from one still connecting.
    # Reporting from here is also what keeps the setting out of the TUI, which
    # never reads `discord_presence` itself.
    if is_pid(subscriber), do: send(subscriber, {:presence_status, :off})
    {:noreply, state}
  end

  def handle_cast({:set_playing, card, subscriber}, state) do
    card = Map.merge(card, %{start_ms: now_ms(), duration_ms: nil})
    state = %{state | card: card, subscriber: subscriber}
    {:noreply, publish(ensure_connection(state))}
  end

  def handle_cast({:anchor, _position_ms, _duration_ms}, %{card: nil} = state) do
    {:noreply, state}
  end

  def handle_cast({:anchor, position_ms, duration_ms}, state) do
    # Computed from the reported position rather than from launch time, so the
    # bar is accurate even though it appears late — the delay affects only when
    # it first shows, not what it shows.
    card = %{state.card | start_ms: now_ms() - position_ms, duration_ms: duration_ms}
    {:noreply, publish(%{state | card: card})}
  end

  def handle_cast(:clear, state) do
    state = cancel_refresh(state)

    state =
      case state.conn do
        nil -> state
        conn -> with_conn_result(state, client().clear(conn))
      end

    {:noreply, %{state | card: nil, published: nil, published_at: nil}}
  end

  # --- timers ----------------------------------------------------------------

  @impl true
  def handle_info(:refresh, state) do
    {:noreply, publish(%{state | refresh_ref: nil})}
  end

  def handle_info(:retry, state) do
    state = %{state | retry_ref: nil}
    {:noreply, publish(ensure_connection(state))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- connecting ------------------------------------------------------------

  defp ensure_connection(%{conn: conn} = state) when not is_nil(conn), do: state
  defp ensure_connection(%{enabled: false} = state), do: state

  defp ensure_connection(state) do
    case client().connect(state.client_id) do
      {:ok, conn} ->
        # A fresh connection resets the backoff and invalidates what was
        # published on the old one, so the next publish always goes out.
        # `reported_failure` is deliberately *not* cleared here — see the
        # moduledoc: it re-arms on a successful publish, not on a socket.
        %{
          state
          | conn: conn,
            backoff_ms: state.timings.backoff_min_ms,
            published: nil,
            published_at: nil
        }

      {:error, reason} ->
        state |> schedule_retry() |> report_failure(reason)
    end
  end

  defp with_conn_result(state, {:ok, conn}), do: %{state | conn: conn}
  defp with_conn_result(state, {:error, _reason}), do: %{state | conn: nil}

  defp report_unavailable(%{reported_failure: true} = state, _reason), do: state

  defp report_unavailable(state, _reason) do
    if is_pid(state.subscriber), do: send(state.subscriber, {:presence_unavailable})
    %{state | reported_failure: true}
  end

  # Every failure, gated or not. The two reports have different audiences and
  # deliberately different frequencies: `{:presence_status, :unavailable}` keeps
  # the now-playing badge honest, so it goes out on each transition, while the
  # footer message above is worth showing a user only once per session.
  defp report_failure(state, reason) do
    state |> report_status(:unavailable) |> report_unavailable(reason)
  end

  defp report_active(state), do: report_status(state, :active)

  defp report_status(%{subscriber: subscriber} = state, status) do
    # A status with no subscriber has nowhere to go; a status the subscriber has
    # since stopped listening for is dropped there, by the TUI.
    if is_pid(subscriber), do: send(subscriber, {:presence_status, status})
    state
  end

  # Bounded exponential backoff, unlike the reference implementation's flat 1s
  # retry — that is wasteful for a TUI left open for hours.
  defp schedule_retry(%{retry_ref: ref} = state) when not is_nil(ref), do: state

  defp schedule_retry(state) do
    ref = Process.send_after(self(), :retry, state.backoff_ms)
    backoff = min(state.backoff_ms * 2, state.timings.backoff_max_ms)
    %{state | retry_ref: ref, backoff_ms: backoff}
  end

  # --- publishing ------------------------------------------------------------

  defp publish(%{card: nil} = state), do: state

  defp publish(state) do
    key = {identity(state.card), anchored?(state.card)}

    if state.conn != nil and key == state.published and fresh?(state) do
      # The card is already live and fresh, so nothing goes out — but the badge
      # still belongs lit, and this is the only path that would leave it dark.
      report_active(state)
    else
      do_publish(state, key)
    end
  end

  defp fresh?(%{published_at: at, timings: %{refresh_ms: ms}}) do
    is_integer(at) and now_ms() - at < ms
  end

  defp do_publish(%{conn: nil} = state, _key) do
    # Nothing to write to; a connection attempt is already scheduled. The card
    # stays in state so it is published the moment one succeeds.
    state
  end

  defp do_publish(state, key) do
    case client().set_activity(state.conn, Activity.build(state.card)) do
      {:ok, conn} ->
        state
        |> Map.put(:conn, conn)
        |> Map.put(:published, key)
        |> Map.put(:published_at, now_ms())
        # Presence demonstrably works again, so the next failure is worth a
        # fresh report.
        |> Map.put(:reported_failure, false)
        |> schedule_refresh()
        |> report_active

      {:error, reason} ->
        # The socket is dead — the only place that is discoverable, since there
        # is no background reader. Close it so the next attempt starts from a
        # clean handshake instead of writing into a half-dead socket.
        client().close(state.conn)
        state |> schedule_retry() |> Map.put(:conn, nil) |> report_failure(reason)
    end
  end

  defp schedule_refresh(state) do
    state = cancel_refresh(state)
    ref = Process.send_after(self(), :refresh, state.timings.refresh_ms)
    %{state | refresh_ref: ref}
  end

  defp cancel_refresh(%{refresh_ref: nil} = state), do: state

  defp cancel_refresh(%{refresh_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | refresh_ref: nil}
  end

  # What the card is *about*. Deliberately excludes the anchor's `start_ms`:
  # `set_playing/1` and `anchor/2` both recompute it from the clock, so a key
  # containing it would differ on every report and the skip in `publish/1`
  # would never once fire.
  defp identity(card), do: {card.title, card.author, card.url, card.video_id}

  # The one timestamp-derived fact that does belong in the key: it is what lets
  # the *first* anchor republish and every later one for the same video be
  # ignored, without relying on the TUI to send only one.
  defp anchored?(card), do: is_integer(card.duration_ms)

  defp now_ms, do: System.system_time(:millisecond)

  # --- seams and settings ----------------------------------------------------

  # The client is behind its own seam, separate from Playmark.TUI.Impl: this is
  # a call Playmark.Presence makes, not one the TUI makes.
  defp client, do: Application.get_env(:playmark, :presence_client_impl, Client)

  defp enabled?, do: Application.get_env(:playmark, :discord_presence, false)

  defp client_id, do: Application.get_env(:playmark, :discord_client_id, @default_client_id)
end
