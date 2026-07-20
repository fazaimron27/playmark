defmodule Playmark.Repo.Migrations.CreatePlaylists do
  use Ecto.Migration

  def change do
    create table(:playlists) do
      add :path, :string, null: false
      add :name, :string, null: false

      timestamps()
    end

    create unique_index(:playlists, [:path])
  end
end
