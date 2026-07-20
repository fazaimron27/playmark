import Config

config :playmark,
  ecto_repos: [Playmark.Repo],
  # Media player used for playback. Supported: :mpv (default) and :vlc.
  # mpv drives yt-dlp itself and handles HLS/muxing natively; vlc has stream
  # URLs pre-resolved by yt-dlp. Override per environment or in a release.
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
