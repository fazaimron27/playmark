defmodule Playmark.Repo.Migrations.CreateBookmarks do
  use Ecto.Migration

  def change do
    create table(:bookmarks) do
      add :url, :string, null: false
      add :title, :string, null: false
      add :channel, :string, null: false

      timestamps()
    end

    create unique_index(:bookmarks, [:url])
  end
end
