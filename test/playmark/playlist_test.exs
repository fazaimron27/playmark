defmodule Playmark.PlaylistTest do
  use ExUnit.Case, async: true

  alias Playmark.Playlist

  describe "changeset/2" do
    test "is valid with path and name" do
      changeset =
        Playlist.changeset(%Playlist{}, %{
          path: "/home/user/Videos",
          name: "Videos"
        })

      assert changeset.valid?
    end

    test "requires path and name" do
      changeset = Playlist.changeset(%Playlist{}, %{})

      assert %{path: ["can't be blank"], name: ["can't be blank"]} = errors(changeset)
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
