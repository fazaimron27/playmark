defmodule Playmark.Player do
  @moduledoc """
  The contract a media-player backend implements.

  `Playmark.Playback` is the public facade the rest of the app talks to; it reads
  configuration, builds an `opts` map, and dispatches to a backend module that
  implements this behaviour (`Playmark.Player.Mpv`, `Playmark.Player.Vlc`). Keeping
  the two players as separate modules behind one contract is what lets them
  diverge where they must — most sharply around captions, which mpv gets inline
  through its own `yt-dlp` pass while VLC needs a separate subtitle download
  handed over as a sidecar file. The behaviour keeps that divergence honest: both
  backends must expose the same entry points.

  Backends are config-free. Everything a backend needs to vary its behaviour
  arrives in `t:opts/0`, resolved once by `Playmark.Playback`, so a backend never
  reads application env itself and is trivial to drive from a test.
  """

  @typedoc """
  Resolved playback options, built by `Playmark.Playback` from user config.

    * `:format` — the `yt-dlp` format string (see `Playmark.Playback.format/0`).
    * `:subtitles?` — whether to attempt captions at all.
    * `:subtitle_default` — first-choice language code for uploader-provided
      captions (e.g. `"en"`).
    * `:subtitle_fallback` — second-choice language for uploader captions, tried
      when no track matches `:subtitle_default`. `nil` means no fallback. When
      neither manual track exists, captions fall back to the auto-generated track
      in the video's spoken language (see `Playmark.Player.Captions`).
    * `:player_client` — the `yt-dlp` YouTube player client to force for stream
      resolution (`web_safari` — returns fetchable URLs).
    * `:subtitle_client` — the `yt-dlp` YouTube player client for downloading
      captions (`default` — exposes tracks with no PO token, unlike the stream
      client). See `Playmark.Player.Captions` for why the two differ.
    * `:progress` — a 1-arity reporter the backend calls with a stage atom
      (`:resolving`, `:captions`, `:playing`) as playback advances, so the UI can
      show step-by-step feedback. Defaults to a no-op, so backends may call it
      unconditionally.
  """
  @type opts :: %{
          format: String.t(),
          subtitles?: boolean(),
          subtitle_default: String.t(),
          subtitle_fallback: String.t() | nil,
          player_client: String.t(),
          subtitle_client: String.t(),
          progress: (atom() -> any())
        }

  @typedoc "`:ok` on clean playback, or a reason string on failure."
  @type result :: :ok | {:error, String.t()}

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
