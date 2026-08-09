defmodule Playmark.PlaylistsTest.StubYouTubePlaylist do
  def metadata(url), do: {:ok, %{title: "Resolved #{url}", channel: "Channel"}}
end

defmodule Playmark.PlaylistsTest do
  use Playmark.DataCase, async: false

  alias Playmark.Playlists
  alias Playmark.Playlists.Playlist

  setup do
    Application.put_env(
      :playmark,
      :youtube_playlist_impl,
      Playmark.PlaylistsTest.StubYouTubePlaylist
    )

    on_exit(fn -> Application.delete_env(:playmark, :youtube_playlist_impl) end)
  end

  test "canonicalizes and saves playlist metadata" do
    assert {:ok, playlist} =
             Playlists.add_playlist("https://www.youtube.com/watch?v=abcdefghijk&list=PL123")

    assert playlist.url == "https://www.youtube.com/playlist?list=PL123"
    assert playlist.title == "Resolved https://www.youtube.com/playlist?list=PL123"
    assert playlist.channel == "Channel"
  end

  test "rejects non-playlist URLs" do
    assert {:error, _} = Playlists.add_playlist("https://www.youtube.com/watch?v=abcdefghijk")
  end

  test "rejects equivalent duplicate URLs" do
    assert {:ok, _} = Playlists.add_playlist("https://youtube.com/playlist?list=PL123")

    assert {:error, changeset} =
             Playlists.add_playlist("https://music.youtube.com/watch?v=x&list=PL123")

    refute changeset.valid?
  end

  test "saves an already-resolved playlist without another metadata lookup" do
    assert {:ok, playlist} =
             Playlists.save_playlist(
               %{
                 url: "https://www.youtube.com/watch?v=abcdefghijk&list=PL123",
                 title: "Course"
               },
               "Teacher"
             )

    assert playlist.url == "https://www.youtube.com/playlist?list=PL123"
    assert playlist.title == "Course"
    assert playlist.channel == "Teacher"
  end

  test "lists newest first and deletes records" do
    older = insert_playlist("PL1", "Older", ~N[2026-01-01 00:00:00])
    newer = insert_playlist("PL2", "Newer", ~N[2026-02-01 00:00:00])
    assert Enum.map(Playlists.list_playlists(), & &1.id) == [newer.id, older.id]

    assert {:ok, _} = Playlists.delete_playlist(newer)
    assert Enum.map(Playlists.list_playlists(), & &1.id) == [older.id]
  end

  defp insert_playlist(id, title, inserted_at) do
    Repo.insert!(%Playlist{
      url: "https://www.youtube.com/playlist?list=#{id}",
      title: title,
      channel: "Channel",
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
  end
end
