defmodule Playmark.HistoryItem do
  use Ecto.Schema
  import Ecto.Changeset

  schema "history_items" do
    field(:title, :string)
    field(:url, :string)
    field(:author, :string)
    field(:local, :boolean, default: false)
    field(:played_at, :utc_datetime)

    timestamps()
  end

  @doc false
  def changeset(history_item, attrs) do
    history_item
    |> cast(attrs, [:title, :url, :author, :local, :played_at])
    |> validate_required([:title, :url, :played_at])
  end
end
