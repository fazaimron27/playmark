defmodule Playmark.HistoryItem do
  use Ecto.Schema
  import Ecto.Changeset

  schema "history_items" do
    field(:title, :string)
    field(:url, :string)
    field(:author, :string)
    field(:local, :boolean, default: false)
    field(:played_at, :utc_datetime)
    field(:resume_position_ms, :integer)
    field(:duration_ms, :integer)

    timestamps()
  end

  @doc false
  def changeset(history_item, attrs) do
    history_item
    |> cast(attrs, [
      :title,
      :url,
      :author,
      :local,
      :played_at,
      :resume_position_ms,
      :duration_ms
    ])
    |> validate_required([:title, :url, :played_at])
    |> validate_number(:resume_position_ms, greater_than_or_equal_to: 0)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
  end
end
