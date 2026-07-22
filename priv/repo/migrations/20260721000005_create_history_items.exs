defmodule Playmark.Repo.Migrations.CreateHistoryItems do
  use Ecto.Migration

  def change do
    create table(:history_items) do
      add :title, :string, null: false
      add :url, :string, null: false
      add :author, :string
      add :local, :boolean, null: false, default: false
      add :played_at, :utc_datetime, null: false

      timestamps()
    end

    # Unique on :url so a rewatch upserts (bumps played_at) instead of adding a
    # duplicate row — the deliberate opposite of queue_items, which allows dupes.
    create unique_index(:history_items, [:url])
    create index(:history_items, [:played_at])
  end
end
