defmodule Playmark.Playlist do
  use Ecto.Schema
  import Ecto.Changeset

  schema "playlists" do
    field(:url, :string)
    field(:title, :string)
    field(:channel, :string)

    timestamps()
  end

  @doc false
  def changeset(playlist, attrs) do
    playlist
    |> cast(attrs, [:url, :title, :channel])
    |> validate_required([:url, :title])
    |> unique_constraint(:url)
  end
end
