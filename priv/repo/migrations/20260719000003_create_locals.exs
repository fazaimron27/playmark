defmodule Playmark.Repo.Migrations.CreateLocals do
  use Ecto.Migration

  def change do
    create table(:locals) do
      add :path, :string, null: false
      add :name, :string, null: false

      timestamps()
    end

    create unique_index(:locals, [:path])
  end
end
