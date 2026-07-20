defmodule Playmark.Playlist do
  use Ecto.Schema
  import Ecto.Changeset

  schema "playlists" do
    field(:path, :string)
    field(:name, :string)

    timestamps()
  end

  @doc false
  def changeset(playlist, attrs) do
    playlist
    |> cast(attrs, [:path, :name])
    |> validate_required([:path, :name])
    |> unique_constraint(:path)
  end
end
