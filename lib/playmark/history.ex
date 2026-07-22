defmodule Playmark.History do
  @moduledoc """
  Context for watch history: a persisted log of what was played, newest first.

  Like `Playmark.Queue` — and unlike `Playmark.Subscriptions` / `Playmark.Playlists`,
  which store only a handle and fetch their contents live — history *is* content,
  a fact about the past that can't be re-derived, so it's stored outright. Each
  item carries a `local` flag (the replay path forks on it, exactly as the queue's
  does) and a `played_at` timestamp.

  History is recorded when playback *begins* (see `Playmark.TUI.Actions.start_play/4`),
  and rewatching a URL *upserts* — `played_at` (and title/author) are refreshed
  rather than a duplicate row added. A unique index on `:url` backs this; it's the
  deliberate opposite of `queue_items`, which allows duplicates. Recording is
  best-effort: a failed write must never interrupt playback.
  """

  import Ecto.Query, only: [from: 2]

  alias Playmark.{HistoryItem, Repo}

  @doc """
  Lists all history items, most recently played first.
  """
  def list_items do
    Repo.all(from(h in HistoryItem, order_by: [desc: h.played_at]))
  end

  @doc """
  Records a play, stamping `played_at` with the current time.

  `attrs` must carry `:title` and `:url`; `:author` and `:local` are optional.
  On a URL already in history this upserts — `title`, `author`, and `played_at`
  are replaced (a rewatch bumps the item to the top) rather than inserting a
  duplicate. Returns `{:ok, item}` or `{:error, changeset}`.
  """
  def record(attrs) when is_map(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("played_at", now)

    %HistoryItem{}
    |> HistoryItem.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:title, :author, :played_at, :updated_at]},
      conflict_target: :url
    )
  end

  @doc """
  Removes one item from the history.
  """
  def remove(%HistoryItem{} = item) do
    Repo.delete(item)
  end

  @doc """
  Empties the history.
  """
  def clear do
    Repo.delete_all(HistoryItem)
    :ok
  end
end
