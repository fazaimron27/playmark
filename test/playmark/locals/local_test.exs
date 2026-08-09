defmodule Playmark.Locals.LocalTest do
  use ExUnit.Case, async: true

  alias Playmark.Locals.Local

  describe "changeset/2" do
    test "accepts a path and name" do
      changeset = Local.changeset(%Local{}, %{path: "/media/videos", name: "videos"})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :path) == "/media/videos"
      assert Ecto.Changeset.get_field(changeset, :name) == "videos"
    end

    test "requires path and name" do
      changeset = Local.changeset(%Local{}, %{})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :path)
      assert Keyword.has_key?(changeset.errors, :name)
    end
  end
end
