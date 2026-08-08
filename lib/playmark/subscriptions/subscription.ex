defmodule Playmark.Subscriptions.Subscription do
  use Ecto.Schema
  import Ecto.Changeset

  schema "subscriptions" do
    field(:url, :string)
    field(:name, :string)

    timestamps()
  end

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:url, :name])
    |> validate_required([:url, :name])
    |> unique_constraint(:url)
  end
end
