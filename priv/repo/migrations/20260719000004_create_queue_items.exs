defmodule Playmark.Repo.Migrations.CreateQueueItems do
  use Ecto.Migration

  def change do
    create table(:queue_items) do
      add :title, :string, null: false
      add :url, :string, null: false
      add :local, :boolean, null: false, default: false
      add :position, :integer, null: false

      timestamps()
    end

    create index(:queue_items, [:position])
  end
end
