defmodule Playmark.Bookmarks.BookmarkTest do
  use ExUnit.Case, async: true

  alias Playmark.Bookmarks.Bookmark

  describe "changeset/2" do
    test "is valid with url, title, and channel" do
      changeset =
        Bookmark.changeset(%Bookmark{}, %{
          url: "https://youtu.be/abc",
          title: "A video",
          channel: "A channel"
        })

      assert changeset.valid?
    end

    test "requires all three fields" do
      changeset = Bookmark.changeset(%Bookmark{}, %{})

      assert %{
               url: ["can't be blank"],
               title: ["can't be blank"],
               channel: ["can't be blank"]
             } = errors(changeset)
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
