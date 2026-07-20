defmodule Playmark.Bookmark do
  use Ecto.Schema
  import Ecto.Changeset

  schema "bookmarks" do
    field(:url, :string)
    field(:title, :string)
    field(:channel, :string)

    timestamps()
  end

  @doc false
  def changeset(bookmark, attrs) do
    bookmark
    |> cast(attrs, [:url, :title, :channel])
    |> validate_required([:url, :title, :channel])
    |> unique_constraint(:url)
  end
end
