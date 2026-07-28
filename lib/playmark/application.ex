defmodule Playmark.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    ensure_data_dir!()
    Playmark.Config.load()
    configure_database()

    children = [
      Playmark.Repo,
      Playmark.Cache
    ]

    opts = [strategy: :one_for_one, name: Playmark.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # Tests create and migrate their throwaway database in test_helper.exs.
      unless Application.get_env(:playmark, :skip_migrations, false), do: migrate!()
      {:ok, pid}
    end
  end

  @doc """
  Absolute path to playmark' data directory (`~/.config/playmark`).
  """
  def data_dir do
    Path.expand("~/.config/playmark")
  end

  @doc """
  Absolute path to the SQLite database file.

  Honors an explicit `:database` set in the Repo config (used by tests);
  otherwise defaults to `~/.config/playmark/playmark.db`.
  """
  def database_path do
    case Application.get_env(:playmark, Playmark.Repo, [])[:database] do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> Path.join(data_dir(), "playmark.db")
    end
  end

  defp ensure_data_dir! do
    File.mkdir_p!(Path.dirname(database_path()))
  end

  # The database path depends on the user's home directory, so it can't live in
  # a static config file. We compute it here and inject it before the Repo boots.
  defp configure_database do
    repo_config =
      :playmark
      |> Application.get_env(Playmark.Repo, [])
      |> Keyword.put(:database, database_path())

    Application.put_env(:playmark, Playmark.Repo, repo_config)
  end

  defp migrate! do
    path = Application.app_dir(:playmark, "priv/repo/migrations")
    # log: false silences the per-boot "Migrations already up" info line. Any
    # migration that actually runs is still surfaced by the migration file's own
    # `== Running ...` output.
    Ecto.Migrator.run(Playmark.Repo, path, :up, all: true, log: false)
  end
end
