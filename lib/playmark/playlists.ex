defmodule Playmark.Playlists do
  @moduledoc """
  Context for registering local directories as playlists.

  A playlist stores only the directory path and a display name (its basename).
  The files inside are never stored — they're read live via `Playmark.Local`
  each time the playlist is opened, so the list is always current. This mirrors
  `Playmark.Subscriptions`, which stores a channel URL and fetches its videos on
  open.
  """

  import Ecto.Query, only: [from: 2]

  alias Playmark.{Playlist, Repo}

  @doc """
  Lists all playlists, newest first.
  """
  def list_playlists do
    Repo.all(from(p in Playlist, order_by: [desc: p.inserted_at]))
  end

  @doc """
  Registers a local directory as a playlist, deriving its name from the
  directory's basename.

  The path is expanded (so `~` and relative paths resolve) and must be an
  existing directory. Returns `{:ok, playlist}` or `{:error, reason}`.
  """
  def add_playlist(path) when is_binary(path) do
    path = path |> String.trim() |> Path.expand()

    if File.dir?(path) do
      %Playlist{}
      |> Playlist.changeset(%{path: path, name: Path.basename(path)})
      |> Repo.insert()
    else
      {:error, "not a directory: #{path}"}
    end
  end

  @doc """
  Deletes a playlist.
  """
  def delete_playlist(%Playlist{} = playlist) do
    Repo.delete(playlist)
  end
end
