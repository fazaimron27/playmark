defmodule Playmark.Playback do
  @moduledoc """
  The playback facade: resolves configuration and dispatches to a player backend.

  The rest of the app talks only to this module (via the `:playback_impl` seam).
  It reads user config once per call, builds the resolved `t:Playmark.Player.opts/0`
  map, and hands off to the backend for the configured player:

    * `:mpv` — `Playmark.Player.Mpv`. The YouTube URL goes straight to
      mpv, which drives `yt-dlp` itself for the stream.
    * `:vlc` — `Playmark.Player.Vlc`. VLC can't fetch YouTube pages, so the backend
      resolves stream URLs with `yt-dlp` first, then hands VLC the raw stream(s).
    * `:ffplay` — `Playmark.Player.Ffplay`. Like VLC it pre-resolves with `yt-dlp`,
      but forces a single muxed stream (no `--input-slave`) and skips captions —
      a minimal, no-extra-install tier.

  The mpv and VLC backends attach captions as a downloaded `.vtt` sidecar; ffplay
  skips captions. Splitting the players into their own modules keeps each one's
  stream quirks contained. This module owns only what they share: reading config
  (player, quality, captions) and the `run/2` helper used by the unmonitored
  ffplay backend. mpv and VLC use `Playmark.Player.Control` for position-aware
  Port and control-socket monitoring.

  ## Player clients (why two of them)

  yt-dlp resolves through a YouTube "player client", and no single client serves
  both needs here:

    * **Streams** (`@player_client`, `web_safari`). YouTube binds most signed URLs
      (default/web/tv/...) to the client that requested them, so a plain HTTP
      client gets `HTTP 403` and the player exits immediately ("opens then
      closes"). `web_safari` hands back an HLS URL a plain HTTP client can fetch.
    * **Captions** (`@subtitle_client`, `default`). `web_safari` *discards* caption
      tracks unless a PO token is supplied, so captions never arrive on that
      client. The `default` client exposes them with no token — but its stream
      URLs 403, so it can't double as the stream client.

  Because the two clients are mutually exclusive, captions can't ride along with
  stream resolution. The mpv and VLC backends download the caption track
  separately (with `@subtitle_client`) into a temp `.vtt` and hand it to the
  player as a sidecar. See `Playmark.Player.Captions`.
  """

  require Logger

  alias Playmark.Player

  # web_safari yields URLs a plain HTTP client can actually fetch (others 403),
  # but YouTube discards its caption tracks unless a PO token is supplied.
  @player_client "web_safari"

  # The caption client. web_safari (above) drops captions with no PO token; the
  # default client exposes them token-free, though its *stream* URLs 403 — so
  # captions download with this client while streams resolve with @player_client.
  # See Playmark.Player.Captions.
  @subtitle_client "default"

  # Default max video height when the user hasn't set :max_height (see
  # Playmark.Config). Prefer this height; fall back to a single muxed stream.
  @default_max_height 1080

  # Caption defaults (see Playmark.Config): captions on, preferring uploader subs
  # in English, no second-choice language, machine-translated auto captions
  # accepted, and the auto-generated track in the video's spoken language as the
  # final fallback.
  @default_subtitles true
  @default_subtitle_default "en"
  @default_subtitle_fallback nil
  @default_subtitle_translate true

  @doc """
  Resolves and plays `url` in the configured player.

  Returns a clean completion reason or `{:error, reason}`. Blocks for the
  duration of playback.
  """
  def play(url) when is_binary(url), do: play(url, player(), nil, &no_op/1, nil)

  @doc """
  Plays `url`, reporting progress through `progress` — a 1-arity function called
  with a stage atom (`:resolving`, `:captions`, `:playing`) as playback advances,
  or an explicit `player` atom (`:mpv`/`:vlc`/`:ffplay`) to override the configured player.

  The progress form is what the TUI uses to drive step-by-step feedback; the
  player form ignores config and is mainly for diagnostics/tests. Caption/quality
  options always come from config.
  """
  def play(url, progress) when is_binary(url) and is_function(progress, 1),
    do: play(url, player(), nil, progress, nil)

  def play(url, player) when is_binary(url) and is_atom(player),
    do: play(url, player, nil, &no_op/1, nil)

  @doc """
  Plays `url` with display `meta` (a `%{title, author}` map handed to the player
  so it shows the video name / channel instead of "unknown title / unknown
  artist"), reporting stages through `progress`. `meta` may be `nil` when unknown,
  and either field within it may be `nil`. This is the form the TUI uses.
  """
  def play(url, meta, progress)
      when is_binary(url) and (is_map(meta) or is_nil(meta)) and is_function(progress, 1),
      do: play(url, player(), meta, progress, nil)

  # Explicit-player form without meta (defaults to nil). Same play/3 arity as the
  # meta form above; the atom second arg is what distinguishes it.
  def play(url, :mpv, progress) when is_binary(url), do: play(url, :mpv, nil, progress, nil)
  def play(url, :vlc, progress) when is_binary(url), do: play(url, :vlc, nil, progress, nil)
  def play(url, :ffplay, progress) when is_binary(url), do: play(url, :ffplay, nil, progress, nil)
  def play(_url, other, _progress), do: {:error, "unsupported player: #{inspect(other)}"}

  @doc """
  Plays `url` with display metadata, a progress reporter, and optionally an
  explicit player or resume offset.
  """
  def play(url, meta, progress, start_position_ms)
      when is_binary(url) and (is_map(meta) or is_nil(meta)) and is_function(progress, 1) and
             (is_nil(start_position_ms) or
                (is_integer(start_position_ms) and start_position_ms >= 0)),
      do: play(url, player(), meta, progress, start_position_ms)

  def play(url, :mpv, meta, progress) when is_binary(url),
    do: play(url, :mpv, meta, progress, nil)

  def play(url, :vlc, meta, progress) when is_binary(url),
    do: play(url, :vlc, meta, progress, nil)

  def play(url, :ffplay, meta, progress) when is_binary(url),
    do: play(url, :ffplay, meta, progress, nil)

  def play(_url, other, _meta, _progress),
    do: {:error, "unsupported player: #{inspect(other)}"}

  def play(url, :mpv, meta, progress, start_position_ms) when is_binary(url),
    do: Player.Mpv.play(url, opts(meta, progress, start_position_ms))

  def play(url, :vlc, meta, progress, start_position_ms) when is_binary(url),
    do: Player.Vlc.play(url, opts(meta, progress, start_position_ms))

  def play(url, :ffplay, meta, progress, _start_position_ms) when is_binary(url),
    do: Player.Ffplay.play(url, opts(meta, progress, nil))

  def play(_url, other, _meta, _progress, _start_position_ms),
    do: {:error, "unsupported player: #{inspect(other)}"}

  @doc """
  Plays a local media file `path` in the configured player.

  Local files need no stream resolution or subtitle download, so the path is
  handed straight to the player. mpv and VLC may auto-load a matching sidecar;
  playmark does not attach one for ffplay. Returns a clean completion reason or
  `{:error, reason}` and blocks for the duration of playback.
  """
  def play_local(path) when is_binary(path), do: play_local(path, player(), nil, &no_op/1, nil)

  @doc """
  Plays local `path`, reporting progress through `progress`, or in an explicit
  `player`. Mirrors `play/2`'s two arities.
  """
  def play_local(path, progress) when is_binary(path) and is_function(progress, 1),
    do: play_local(path, player(), nil, progress, nil)

  def play_local(path, player) when is_binary(path) and is_atom(player),
    do: play_local(path, player, nil, &no_op/1, nil)

  @doc """
  Plays local `path` with display `meta` and a progress reporter. The form the
  TUI uses; `meta` (and either field within it) may be `nil`.
  """
  def play_local(path, meta, progress)
      when is_binary(path) and (is_map(meta) or is_nil(meta)) and is_function(progress, 1),
      do: play_local(path, player(), meta, progress, nil)

  # Explicit-player form without meta (defaults to nil). Same play_local/3 arity
  # as the meta form above; the atom second arg distinguishes it.
  def play_local(path, :mpv, progress) when is_binary(path),
    do: play_local(path, :mpv, nil, progress, nil)

  def play_local(path, :vlc, progress) when is_binary(path),
    do: play_local(path, :vlc, nil, progress, nil)

  def play_local(path, :ffplay, progress) when is_binary(path),
    do: play_local(path, :ffplay, nil, progress, nil)

  def play_local(_path, other, _progress), do: {:error, "unsupported player: #{inspect(other)}"}

  @doc """
  Plays local `path` with display metadata, a progress reporter, and optionally
  an explicit player or resume offset.
  """
  def play_local(path, meta, progress, start_position_ms)
      when is_binary(path) and (is_map(meta) or is_nil(meta)) and is_function(progress, 1) and
             (is_nil(start_position_ms) or
                (is_integer(start_position_ms) and start_position_ms >= 0)),
      do: play_local(path, player(), meta, progress, start_position_ms)

  def play_local(path, :mpv, meta, progress) when is_binary(path),
    do: play_local(path, :mpv, meta, progress, nil)

  def play_local(path, :vlc, meta, progress) when is_binary(path),
    do: play_local(path, :vlc, meta, progress, nil)

  def play_local(path, :ffplay, meta, progress) when is_binary(path),
    do: play_local(path, :ffplay, meta, progress, nil)

  def play_local(_path, other, _meta, _progress),
    do: {:error, "unsupported player: #{inspect(other)}"}

  def play_local(path, :mpv, meta, progress, start_position_ms) when is_binary(path),
    do: Player.Mpv.play_local(path, opts(meta, progress, start_position_ms))

  def play_local(path, :vlc, meta, progress, start_position_ms) when is_binary(path),
    do: Player.Vlc.play_local(path, opts(meta, progress, start_position_ms))

  def play_local(path, :ffplay, meta, progress, _start_position_ms) when is_binary(path),
    do: Player.Ffplay.play_local(path, opts(meta, progress, nil))

  def play_local(_path, other, _meta, _progress, _start_position_ms),
    do: {:error, "unsupported player: #{inspect(other)}"}

  @doc """
  The configured player. Falls back to `:mpv` only when no application setting
  exists; the shipped configuration selects `:vlc`.
  """
  def player, do: Application.get_env(:playmark, :player, :mpv)

  @doc """
  The external executable name for the configured (or given) player.
  """
  def executable(player \\ player())
  def executable(:mpv), do: Player.Mpv.executable()
  def executable(:vlc), do: Player.Vlc.executable()
  def executable(:ffplay), do: Player.Ffplay.executable()

  @doc "Whether the configured player supports persisted resume checkpoints."
  def resume_supported?, do: player() in [:mpv, :vlc]

  @doc """
  The user's `:max_height` cap in pixels (default #{@default_max_height}), the
  ceiling `format/0` builds its selector around.
  """
  def max_height, do: Application.get_env(:playmark, :max_height, @default_max_height)

  @doc """
  The yt-dlp format string, honoring the user's `:max_height` cap (default
  #{@default_max_height}). Prefers video up to that height plus best audio,
  falling back to a single muxed stream.
  """
  def format, do: "bestvideo[height<=#{max_height()}]+bestaudio/best"

  @doc """
  Whether captions are enabled (default `#{@default_subtitles}`).
  """
  def subtitles?, do: Application.get_env(:playmark, :subtitles, @default_subtitles)

  @doc """
  The first-choice caption language code for uploader-provided subtitles
  (default `#{inspect(@default_subtitle_default)}`).
  """
  def subtitle_default,
    do: Application.get_env(:playmark, :subtitle_default, @default_subtitle_default)

  @doc """
  The second-choice caption language for uploader-provided subtitles, tried when
  no track matches `subtitle_default/0`. `nil` (the default) means no fallback
  language.
  """
  def subtitle_fallback,
    do: Application.get_env(:playmark, :subtitle_fallback, @default_subtitle_fallback)

  @doc """
  Whether a machine-translated auto caption track may satisfy the requested
  language (default `#{@default_subtitle_translate}`).

  YouTube lists the spoken transcript machine-translated into ~150 languages
  among a video's automatic captions, so with this on a request for `"en"` is
  met even on a video with no English audio or uploader subtitles. Turn it off to
  keep the previous behavior, where an unmatched request falls through to the
  auto-generated track in the video's *spoken* language. See
  `Playmark.Player.Captions`.
  """
  def subtitle_translate,
    do: Application.get_env(:playmark, :subtitle_translate, @default_subtitle_translate)

  @doc """
  Delegates to `Playmark.Player.Vlc.parse_stream_urls/1`.

  Kept here as the historical entry point; the parsing itself lives with the VLC
  backend that produces the `yt-dlp -g` output.
  """
  defdelegate parse_stream_urls(output), to: Player.Vlc

  @doc """
  Runs `executable` with `args`, returning `{:ok, :unknown}` on exit 0 or
  `{:error, reason}`.

  Shared by the player backends; blocks for the child's lifetime.
  """
  def run(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, :unknown}

      {output, code} ->
        {:error, "#{executable} exited with #{code}: #{String.trim(output)}"}
    end
  end

  @doc """
  Reports a playback `stage` atom through the reporter in `opts`.

  Backends call this as they advance (`:resolving`, `:captions`, `:playing`) so
  the UI can show step-by-step feedback. The reporter defaults to a no-op, so a
  backend may call this unconditionally regardless of how it was invoked.
  """
  def report(%{progress: progress}, stage) when is_function(progress, 1) do
    progress.(stage)
    :ok
  end

  # Opts built without a reporter (e.g. the mix playmark.debug caption probe) —
  # reporting is a no-op so callers may report unconditionally.
  def report(_opts, _stage), do: :ok

  # The resolved options handed to a player backend, built from config once per
  # play call so backends never read application env themselves. `progress` is a
  # 1-arity reporter the backend calls with a stage atom as it advances; it
  # defaults to a no-op so backends may call it unconditionally. `meta` is a
  # `%{title, author}` display map (or nil); each field flows to a player flag
  # (nil when unknown — the backend then adds no flag for it).
  defp opts(meta, progress, start_position_ms) do
    %{
      format: format(),
      subtitles?: subtitles?(),
      subtitle_default: subtitle_default(),
      subtitle_fallback: subtitle_fallback(),
      subtitle_translate: subtitle_translate(),
      player_client: @player_client,
      subtitle_client: @subtitle_client,
      progress: progress,
      start_position_ms: start_position_ms,
      title: meta_field(meta, :title),
      author: meta_field(meta, :author)
    }
  end

  # A field from the optional display-meta map: nil when there's no map or the
  # key is absent, so a caller may pass a partial map (or none at all).
  defp meta_field(nil, _key), do: nil
  defp meta_field(meta, key) when is_map(meta), do: Map.get(meta, key)

  defp no_op(_stage), do: :ok
end
