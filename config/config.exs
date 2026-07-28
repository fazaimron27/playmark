import Config

config :playmark,
  ecto_repos: [Playmark.Repo],
  # Media player used for playback. Supported: :vlc (default), :mpv, and :ffplay.
  # mpv drives yt-dlp itself; vlc and ffplay receive URLs pre-resolved by yt-dlp.
  # Override per environment or in ~/.config/playmark/config.env.
  player: :vlc

config :playmark, Playmark.Repo,
  # The concrete database path is computed and injected at runtime in
  # Playmark.Application.start/2 so we can expand "~" and create the
  # containing directory before the Repo boots.
  database: "",
  journal_mode: :wal,
  busy_timeout: 5_000,
  # Single-user local TUI: one connection avoids a WAL-init race on first boot.
  pool_size: 1

config :logger, level: :info

import_config "#{config_env()}.exs"
