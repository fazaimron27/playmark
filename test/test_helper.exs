alias Ecto.Adapters.SQLite3, as: Adapter

# Start with a clean database file, then migrate it once before any test runs.
_ = Adapter.storage_down(Playmark.Repo.config())

case Adapter.storage_up(Playmark.Repo.config()) do
  :ok -> :ok
  {:error, :already_up} -> :ok
end

Application.ensure_all_started(:playmark)

migrations = Application.app_dir(:playmark, "priv/repo/migrations")
Ecto.Migrator.run(Playmark.Repo, migrations, :up, all: true)

ExUnit.start()
