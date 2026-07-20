defmodule Playmark.Cache do
  @moduledoc """
  A generic in-memory key/value cache backed by ETS.

  A GenServer owns a public, read-optimized ETS table. Reads (`get/1`) run
  directly in the calling process — including `Task.async_stream` children —
  without serializing through the GenServer. Writes go through the process so the
  size cap is enforced in one place. The cap is crude on purpose: when exceeded we
  drop the whole table rather than track an LRU. This is a single-user local app
  and cached values are cheap to rebuild, so simplicity wins.

  Keys and values are arbitrary terms. Callers own their own key scheme; namespace
  keys (e.g. `{:title, id}`) if a single table is shared across concerns.

  ## What belongs here

  Only values that are safe to memoize — effectively immutable, or where a stale
  read is harmless. It must not be used to cache anything that needs to stay live
  (e.g. a channel's video *set*, which is refetched on every open per CLAUDE.md).
  """

  use GenServer

  @table __MODULE__
  @max_entries 2_000

  # --- client API ----------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Looks up a key. Returns `{:ok, value}` on a hit, `:miss` otherwise.

  Reads the ETS table directly from the calling process.
  """
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  end

  @doc """
  Stores a value under a key.
  """
  def put(key, value) do
    GenServer.cast(__MODULE__, {:put, key, value})
  end

  @doc """
  Empties the cache. Used by tests to isolate runs.
  """
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  Blocks until all casts enqueued before this call have been processed.

  `put/2` is a cast, so a subsequent `get/1` (a direct ETS read) can race it. A
  synchronous round-trip flushes the mailbox — message ordering guarantees the
  earlier cast ran first. Useful in tests that write then immediately read.
  """
  def sync do
    GenServer.call(__MODULE__, :sync)
  end

  # --- server callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:put, key, value}, state) do
    # Crude bound: once the table is full, drop everything and start over rather
    # than evict a single entry. Cached values are cheap to rebuild on demand.
    if :ets.info(@table, :size) >= @max_entries do
      :ets.delete_all_objects(@table)
    end

    :ets.insert(@table, {key, value})
    {:noreply, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  def handle_call(:sync, _from, state), do: {:reply, :ok, state}
end
