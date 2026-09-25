import Config

config :playmark,
  ecto_repos: [Playmark.Repo],
  # Media player used for playback. Supported: :mpv (default), :vlc, and :ffplay.
  # mpv drives yt-dlp itself; vlc and ffplay receive URLs pre-resolved by yt-dlp.
  #
  # mpv is the default for two reasons. It hands the stream to ffmpeg, which
  # retries and skips HLS segments YouTube intermittently 403s, where VLC's own
  # demuxer aborts the input (mitigated by --demux=avformat, see
  # Playmark.Player.Vlc, but mpv needs no mitigation). And it reports exact
  # position and end-of-file over JSON IPC, so resume checkpoints and completion
  # detection are precise rather than inferred from a polled position.
  #
  # Override per environment or in ~/.config/playmark/config.env.
  player: :mpv

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
