import Config

# Tests use a throwaway on-disk SQLite database that is migrated once at
# startup (see test_helper.exs). The Application skips its own auto-migration.
config :playmark, Playmark.Repo,
  database: Path.expand("../playmark_test.db", __DIR__),
  pool_size: 1

config :playmark, :skip_migrations, true

# Never read the real ~/.config/playmark/config.env during tests. Point the
# config loader at a path that doesn't exist so a developer's actual settings
# can't leak into (or be clobbered by) the suite. ConfigTest overrides this per
# test to point at an isolated temp file.
config :playmark, :config_path, Path.expand("../test/nonexistent_config.env", __DIR__)

config :logger, level: :warning
