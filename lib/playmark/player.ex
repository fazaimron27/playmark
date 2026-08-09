defmodule Playmark.Player do
  @moduledoc """
  The contract a media-player backend implements.

  `Playmark.Player.Playback` is the public facade the rest of the app talks to; it reads
  configuration, builds an `opts` map, and dispatches to a backend module that
  implements this behaviour (`Playmark.Player.Mpv`, `Playmark.Player.Vlc`, or
  `Playmark.Player.Ffplay`). Keeping the players as separate modules behind one
  contract lets them diverge where they must: mpv and VLC download caption
  sidecars, while ffplay skips captions; VLC and ffplay pre-resolve streams, while
  mpv drives `yt-dlp` itself. Every backend still exposes the same entry points.

  Playback options are resolved centrally and passed in `t:opts/0`; backend
  argument construction remains directly testable without launching a player.
  """

  @typedoc """
  Resolved playback options, built by `Playmark.Player.Playback` from user config.

    * `:format` — the `yt-dlp` format string (see `Playmark.Player.Playback.format/0`).
    * `:subtitles?` — whether to attempt captions at all.
    * `:subtitle_default` — first-choice language code for uploader-provided
      captions (e.g. `"en"`).
    * `:subtitle_fallback` — second-choice language for uploader captions, tried
      when no track matches `:subtitle_default`. `nil` means no fallback.
    * `:subtitle_translate` — whether a machine-translated auto caption track may
      satisfy either requested language when no uploader track matches. With it
      off, an unmatched request falls through to the auto-generated track in the
      video's spoken language (see `Playmark.Player.Captions`).
    * `:player_client` — the `yt-dlp` YouTube player client to force for stream
      resolution (`web_safari` — returns fetchable URLs).
    * `:subtitle_client` — the `yt-dlp` YouTube player client for downloading
      captions (`default` — exposes tracks with no PO token, unlike the stream
      client). See `Playmark.Player.Captions` for why the two differ.
    * `:progress` — a 1-arity reporter the backend calls with preparation stages
      and playback checkpoint events. Defaults to a no-op, so backends may call
      it unconditionally.
    * `:start_position_ms` — a persisted resume offset, or `nil` to start over.
    * `:title` — the display title to hand the player (via `--force-media-title`
      for mpv, `--meta-title` for VLC, and `-window_title` for ffplay). Without it
      the player falls back to its own placeholder, since a pre-resolved stream
      URL carries no metadata. `nil` or blank means no title flag is added.
    * `:author` — the display artist/author (the YouTube channel) to hand the
      player. Only VLC consumes it (`--meta-artist`); mpv and ffplay ignore it.
      `nil` or blank means no artist flag is added.
  """
  @type opts :: %{
          format: String.t(),
          subtitles?: boolean(),
          subtitle_default: String.t(),
          subtitle_fallback: String.t() | nil,
          subtitle_translate: boolean(),
          player_client: String.t(),
          subtitle_client: String.t(),
          progress: (term() -> any()),
          start_position_ms: non_neg_integer() | nil,
          title: String.t() | nil,
          author: String.t() | nil
        }

  @typedoc "The reason playback ended cleanly, or a reason string on failure."
  @type result ::
          {:ok, :completed | :stopped | :unknown}
          | {:error, String.t()}

  @doc """
  Plays a YouTube `url`, blocking until the user closes the player.
  """
  @callback play(url :: String.t(), opts()) :: result()

  @doc """
  Plays a local media file `path`, blocking until the user closes the player.
  """
  @callback play_local(path :: String.t(), opts()) :: result()

  @doc """
  The external executable this backend shells out to (e.g. `"mpv"`).
  """
  @callback executable() :: String.t()
end
