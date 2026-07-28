defmodule Playmark.Local do
  use Ecto.Schema
  import Ecto.Changeset

  schema "locals" do
    field(:path, :string)
    field(:name, :string)

    timestamps()
  end

  @doc false
  def changeset(local, attrs) do
    local
    |> cast(attrs, [:path, :name])
    |> validate_required([:path, :name])
    |> unique_constraint(:path)
  end
end
