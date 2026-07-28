defmodule Playmark.Repo.Migrations.CreatePlaylists do
  use Ecto.Migration

  def change do
    create table(:playlists) do
      add :url, :string, null: false
      add :title, :string, null: false
      add :channel, :string

      timestamps()
    end

    create unique_index(:playlists, [:url])
  end
end
