defmodule Playmark.Repo.Migrations.CreateSubscriptions do
  use Ecto.Migration

  def change do
    create table(:subscriptions) do
      add :url, :string, null: false
      add :name, :string, null: false

      timestamps()
    end

    create unique_index(:subscriptions, [:url])
  end
end
