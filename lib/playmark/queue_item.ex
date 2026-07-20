defmodule Playmark.QueueItem do
  use Ecto.Schema
  import Ecto.Changeset

  schema "queue_items" do
    field(:title, :string)
    field(:url, :string)
    field(:local, :boolean, default: false)
    field(:position, :integer)

    timestamps()
  end

  @doc false
  def changeset(queue_item, attrs) do
    queue_item
    |> cast(attrs, [:title, :url, :local, :position])
    |> validate_required([:title, :url, :position])
  end
end
