defmodule Playmark.Queue do
  @moduledoc """
  Context for the playback queue: an ordered, persisted list of items to play in
  sequence.

  Unlike `Playmark.Subscriptions` and `Playmark.Playlists` — which store only a
  handle (URL / directory) and fetch their contents live — the queue *is*
  user-curated content, so it's stored outright, ordering included. Each item
  carries a `local` flag because the play path forks on it: local files go
  straight to the player (`Playmark.Playback.play_local/2`), everything else is a
  YouTube URL that may need stream resolution (`play/2`). The active view can't
  decide this once a queue mixes sources, so the item must.

  Order is an explicit integer `position` column. Appends land at the tail;
  reordering swaps a neighbour's position. The TUI holds the list in memory and
  refreshes it from here after each mutation.
  """

  import Ecto.Query, only: [from: 2]

  alias Playmark.{QueueItem, Repo}

  @doc """
  Lists all queue items in play order (lowest `position` first).
  """
  def list_items do
    Repo.all(from(q in QueueItem, order_by: [asc: q.position]))
  end

  @doc """
  The next item to play (lowest `position`), or `nil` if the queue is empty.
  """
  def head do
    Repo.one(from(q in QueueItem, order_by: [asc: q.position], limit: 1))
  end

  @doc """
  Appends an item to the tail of the queue.

  `attrs` must carry `:title`, `:url`, and `:local`; `:position` is assigned
  here as `max(position) + 1`. Returns `{:ok, item}` or `{:error, changeset}`.
  """
  def enqueue(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("position", next_position())

    %QueueItem{}
    |> QueueItem.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Removes one item from the queue.
  """
  def remove(%QueueItem{} = item) do
    Repo.delete(item)
  end

  @doc """
  Removes the item with the given id, if it still exists.

  Used by auto-advance to drop the item that just finished, named by id so it
  stays correct even if the modal reordered the queue mid-playback. A no-op
  (returns `:ok`) when the id is already gone.
  """
  def remove_by_id(id) do
    case Repo.get(QueueItem, id) do
      nil -> :ok
      item -> Repo.delete(item) && :ok
    end
  end

  @doc """
  Empties the queue.
  """
  def clear do
    Repo.delete_all(QueueItem)
    :ok
  end

  @doc """
  Moves `item` one step towards the head, swapping positions with its predecessor.

  A no-op (returns `:ok`) when the item is already at the head.
  """
  def move_up(%QueueItem{} = item) do
    case Repo.one(
           from(q in QueueItem,
             where: q.position < ^item.position,
             order_by: [desc: q.position],
             limit: 1
           )
         ) do
      nil -> :ok
      prev -> swap(item, prev)
    end
  end

  @doc """
  Moves `item` one step towards the tail, swapping positions with its successor.

  A no-op (returns `:ok`) when the item is already at the tail.
  """
  def move_down(%QueueItem{} = item) do
    case Repo.one(
           from(q in QueueItem,
             where: q.position > ^item.position,
             order_by: [asc: q.position],
             limit: 1
           )
         ) do
      nil -> :ok
      next -> swap(item, next)
    end
  end

  # Swap two items' positions. SQLite has a single writer and this app a single
  # connection, so there's no concurrent-writer race to guard against. Positions
  # carry a NOT NULL but no unique constraint, so a transient duplicate mid-swap
  # is harmless. The two updates run in a transaction so a crash between them
  # can't leave the swap half-applied (two items sharing a position, i.e. a
  # non-deterministic order) — either both land or neither does.
  defp swap(a, b) do
    Repo.transaction(fn ->
      Repo.update!(QueueItem.changeset(a, %{"position" => b.position}))
      Repo.update!(QueueItem.changeset(b, %{"position" => a.position}))
    end)

    :ok
  end

  defp next_position do
    (Repo.one(from(q in QueueItem, select: max(q.position))) || 0) + 1
  end
end
