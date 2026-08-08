defmodule Playmark.Playlists do
  @moduledoc """
  Context for saved YouTube playlists.

  Only playlist metadata is persisted. Entries are fetched live through
  `Playmark.Source.YouTubePlaylist` whenever a playlist is opened.
  """

  import Ecto.Query, only: [from: 2]

  alias Playmark.Source.YouTubePlaylist
  alias Playmark.{Playlist, Repo, YouTube}

  @doc "Lists saved YouTube playlists, newest first."
  def list_playlists do
    Repo.all(from(playlist in Playlist, order_by: [desc: playlist.inserted_at]))
  end

  @doc "Resolves and saves a YouTube playlist URL."
  def add_playlist(input) when is_binary(input) do
    with {:ok, url} <- YouTube.canonical_playlist_url(input),
         {:ok, metadata} <- youtube_playlist().metadata(url) do
      insert_playlist(url, metadata.title, Map.get(metadata, :channel))
    end
  end

  @doc "Saves an already-resolved YouTube playlist container."
  def save_playlist(%{url: input, title: title} = playlist, channel \\ nil)
      when is_binary(input) and is_binary(title) do
    with {:ok, url} <- YouTube.canonical_playlist_url(input) do
      insert_playlist(url, title, Map.get(playlist, :channel) || channel)
    end
  end

  @doc "Deletes a saved YouTube playlist."
  def delete_playlist(%Playlist{} = playlist), do: Repo.delete(playlist)

  defp insert_playlist(url, title, channel) do
    %Playlist{}
    |> Playlist.changeset(%{url: url, title: title, channel: channel})
    |> Repo.insert()
  end

  defp youtube_playlist,
    do: Application.get_env(:playmark, :youtube_playlist_impl, YouTubePlaylist)
end
