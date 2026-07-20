defmodule Playmark.BookmarksTest do
  use Playmark.DataCase, async: false

  alias Playmark.{Bookmark, Bookmarks}

  describe "list_bookmarks/0" do
    test "returns bookmarks newest first" do
      older = insert_bookmark("https://youtu.be/a", "Older", ~N[2026-01-01 00:00:00])
      newer = insert_bookmark("https://youtu.be/b", "Newer", ~N[2026-02-01 00:00:00])

      assert [first, second] = Bookmarks.list_bookmarks()
      assert first.id == newer.id
      assert second.id == older.id
    end
  end

  describe "delete_bookmark/1" do
    test "removes the bookmark" do
      bookmark = insert_bookmark("https://youtu.be/c", "Doomed")

      assert {:ok, _} = Bookmarks.delete_bookmark(bookmark)
      assert Bookmarks.list_bookmarks() == []
    end
  end

  defp insert_bookmark(url, title, inserted_at \\ ~N[2026-01-15 00:00:00]) do
    Repo.insert!(%Bookmark{
      url: url,
      title: title,
      channel: "Chan",
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
  end
end
