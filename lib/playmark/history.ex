defmodule Playmark.History do
  @moduledoc """
  Context for watch history: a persisted log of what was played, newest first.

  Like `Playmark.Queue` -- and unlike subscriptions, playlists, and locals, which
  fetch source contents live -- history *is* content,
  a fact about the past that can't be re-derived, so it's stored outright. Each
  item carries a `local` flag (the replay path forks on it, exactly as the queue's
  does) and a `played_at` timestamp.

  History is recorded when playback *begins* (see
  `Playmark.TUI.PlaybackActions.start_play/4`),
  and rewatching a URL *upserts* — `played_at` (and title/author) are refreshed
  rather than a duplicate row added. A unique index on `:url` backs this; it's the
  deliberate opposite of `queue_items`, which allows duplicates. Recording is
  best-effort: a failed write must never interrupt playback. For players with a
  stable control interface, the same row stores a resumable position and known
  duration; checkpoint updates do not change `played_at`.
  """

  import Ecto.Query, only: [from: 2]

  alias Playmark.History.Item
  alias Playmark.Repo

  @doc """
  Lists all history items, most recently played first.
  """
  def list_items do
    Repo.all(from(h in Item, order_by: [desc: h.played_at]))
  end

  @doc """
  Returns the persisted resume checkpoint for `url`, or `nil` when none exists.

  A checkpoint is returned only when both values are present and non-negative.
  """
  def get_checkpoint(url) when is_binary(url) do
    Repo.one(
      from(h in Item,
        where:
          h.url == ^url and not is_nil(h.resume_position_ms) and
            h.resume_position_ms >= 0 and not is_nil(h.duration_ms) and h.duration_ms >= 0,
        select: %{
          resume_position_ms: h.resume_position_ms,
          duration_ms: h.duration_ms
        }
      )
    )
  end

  @doc """
  Saves the resume checkpoint for the history item identified by `url`.

  `resume_position_ms` and `duration_ms` must be non-negative integers. The
  item's `played_at` value is not changed. Returns `{:ok, item}`,
  `{:error, changeset}`, or `{:error, :not_found}`.
  """
  def save_checkpoint(url, resume_position_ms, duration_ms) when is_binary(url) do
    case Repo.get_by(Item, url: url) do
      nil ->
        {:error, :not_found}

      item ->
        item
        |> Item.changeset(%{
          resume_position_ms: resume_position_ms,
          duration_ms: duration_ms
        })
        |> Ecto.Changeset.validate_required([:resume_position_ms, :duration_ms])
        |> Repo.update()
    end
  end

  @doc """
  Clears the resume checkpoint for `url`.

  This is a no-op when the URL is not in history and does not change `played_at`.
  """
  def clear_checkpoint(url) when is_binary(url) do
    from(h in Item, where: h.url == ^url)
    |> Repo.update_all(set: [resume_position_ms: nil, duration_ms: nil])

    :ok
  end

  @doc """
  Records a play, stamping `played_at` with the current time.

  `attrs` must carry `:title` and `:url`; `:author` and `:local` are optional.
  On a URL already in history this upserts — `title`, `author`, and `played_at`
  are replaced (a rewatch bumps the item to the top) rather than inserting a
  duplicate. Any resume checkpoint is preserved. Returns `{:ok, item}` or
  `{:error, changeset}`.
  """
  def record(attrs) when is_map(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("played_at", now)

    %Item{}
    |> Item.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:title, :author, :played_at, :updated_at]},
      conflict_target: :url
    )
  end

  @doc """
  Removes one item from the history.
  """
  def remove(%Item{} = item) do
    Repo.delete(item)
  end

  @doc """
  Empties the history.
  """
  def clear do
    Repo.delete_all(Item)
    :ok
  end
end
