defmodule Playmark.Bookmarks do
  @moduledoc """
  Context for creating and listing bookmarks.
  """

  import Ecto.Query, only: [from: 2]

  alias Playmark.{Bookmark, Metadata, Repo}

  @doc """
  Lists all bookmarks, newest first.
  """
  def list_bookmarks do
    Repo.all(from(b in Bookmark, order_by: [desc: b.inserted_at]))
  end

  @doc """
  Fetches metadata for the given YouTube URL and stores a bookmark.

  Returns `{:ok, bookmark}` or `{:error, reason}`.
  """
  def add_bookmark(url) when is_binary(url) do
    url = String.trim(url)

    with {:ok, %{title: title, channel: channel}} <- Metadata.fetch(url) do
      %Bookmark{}
      |> Bookmark.changeset(%{url: url, title: title, channel: channel})
      |> Repo.insert()
    end
  end

  @doc """
  Deletes a bookmark.
  """
  def delete_bookmark(%Bookmark{} = bookmark) do
    Repo.delete(bookmark)
  end
end
