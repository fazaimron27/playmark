defmodule Playmark.PlaylistsTest do
  use Playmark.DataCase, async: false

  alias Playmark.{Playlist, Playlists}

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "playmark_playlists_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "add_playlist/1" do
    test "registers an existing directory, deriving the name from its basename", %{dir: dir} do
      assert {:ok, playlist} = Playlists.add_playlist(dir)
      assert playlist.path == dir
      assert playlist.name == Path.basename(dir)
    end

    test "expands the path before storing it", %{dir: dir} do
      # A relative-looking path with . segments resolves to the same absolute dir.
      messy = Path.join(dir, ".")

      assert {:ok, playlist} = Playlists.add_playlist(messy)
      assert playlist.path == dir
    end

    test "rejects a path that is not a directory" do
      assert {:error, reason} = Playlists.add_playlist("/nonexistent/playmark/path")
      assert reason =~ "not a directory"
    end

    test "rejects a duplicate path", %{dir: dir} do
      assert {:ok, _} = Playlists.add_playlist(dir)
      assert {:error, changeset} = Playlists.add_playlist(dir)
      refute changeset.valid?
    end
  end

  describe "list_playlists/0" do
    test "returns playlists newest first" do
      older = insert_playlist("/tmp/a", "A", ~N[2026-01-01 00:00:00])
      newer = insert_playlist("/tmp/b", "B", ~N[2026-02-01 00:00:00])

      assert [first, second] = Playlists.list_playlists()
      assert first.id == newer.id
      assert second.id == older.id
    end
  end

  describe "delete_playlist/1" do
    test "removes the playlist" do
      playlist = insert_playlist("/tmp/doomed", "Doomed")

      assert {:ok, _} = Playlists.delete_playlist(playlist)
      assert Playlists.list_playlists() == []
    end
  end

  defp insert_playlist(path, name, inserted_at \\ ~N[2026-01-15 00:00:00]) do
    Repo.insert!(%Playlist{
      path: path,
      name: name,
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
  end
end
