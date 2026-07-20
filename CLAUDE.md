# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

playmark is a terminal UI (Elixir + `ex_ratatui`) for bookmarking YouTube videos, subscribing to channels, and searching YouTube, then playing videos in an external player — all without a YouTube API key. Metadata comes from YouTube's public oEmbed endpoint; channel listings, search, and stream resolution shell out to `yt-dlp`; playback hands off to `mpv` or `vlc`.

## Commands

```sh
mix deps.get              # install dependencies
mix compile               # compile (use --warnings-as-errors before finishing a change)
mix test                  # run the full suite
mix test path/to/file_test.exs          # single file
mix test path/to/file_test.exs:42       # single test at line 42
mix format                # format (run before finishing a change)
mix playmark               # launch the TUI (requires yt-dlp + configured player on PATH)
mix playmark.debug <url>          # diagnose playback for one URL outside the TUI (see below)
mix playmark.debug --subs <url>   # diagnose why captions do / don't appear
```

`mix playmark.debug` is a standalone diagnostic for the playback boundary, run outside the TUI so its output is visible. Probe mode (default) tries each yt-dlp player client and reports which yields URLs a plain HTTP client (VLC) can fetch; `--subs <url>` diagnoses captions (compares what each client exposes, runs the real `Playmark.Player.Captions` download, prints the args each player receives); `--play` runs the real VLC command with verbose, timestamped logging to catch a mid-stream death; `--mem` reports the BEAM's memory footprint, and with a channel URL shows the `Playmark.Cache` title cache serving a warm reload from ETS. This task is what identified both the `web_safari` stream client and the separate `default` caption client.

## Runtime dependencies

The app requires `yt-dlp` and one media player (`mpv` default, or `vlc`) on the `PATH`. `Playmark.SystemCheck` verifies these at TUI launch and exits with install hints if missing. It only requires the *configured* player, not both.

## Architecture

Layers, outermost to innermost:

- **`Playmark.TUI`** — the `ex_ratatui` app shell. Owns the runtime callbacks (`mount/1`, `handle_event/2`, `handle_info/2`, `render/2`) and delegates:
  - **`Playmark.TUI.Actions`** — state transitions: key handlers, navigation, and the task spawners.
  - **`Playmark.TUI.View`** — pure `state -> [{widget, rect}]` rendering, no side effects.
- **Contexts** (`Playmark.Bookmarks`, `Playmark.Subscriptions`, `Playmark.Playlists`) — Ecto-backed CRUD over `Bookmark` / `Subscription` / `Playlist` schemas.
- **External-IO modules** (`Playmark.Metadata`, `Playmark.Channel`, `Playmark.Search`, `Playmark.Local`, `Playmark.Playback` + its `Playmark.Player.Mpv`/`Playmark.Player.Vlc` backends) — the oEmbed / `yt-dlp` / filesystem / player boundary. Each shells out, hits the network, or reads the disk and returns a tagged tuple (`{:ok, _}` / `{:error, reason}`). `Playmark.Search` runs a `yt-dlp` `ytsearchN:` query and reuses `Playmark.Channel`'s `parse_videos/1` + `enrich_titles/1`, so a search result is shaped identically to a channel video and flows into the same `:videos` mode. `Playmark.Local.list_files/1` reads a directory's top-level media files and returns the same `%{id, title, url}` shape (here `url` is the file path), so local files flow into `:videos` mode too.
- **`Playmark.Cache`** — a generic ETS-backed key/value cache owned by a GenServer in the supervision tree (`Playmark.Application`). Reads (`get/1`) run directly against a public, read-optimized ETS table from the calling process — including `Task.async_stream` children — while writes (`put/2`, a cast) funnel through the GenServer so the size cap is enforced in one place. The cap is crude: at `@max_entries` it drops the whole table rather than track an LRU. Only memoize values that are effectively immutable or where a stale read is harmless; do **not** cache anything that must stay live (e.g. a channel's video set). Its one current user is title enrichment (see below).

### The non-blocking task model (central to the TUI)

Anything that shells out or hits the network — adding, listing a channel's videos, playback — runs in a spawned `Task` that sends its result back to the runtime process via a message handled in `Playmark.TUI.handle_info/2`. `handle_event/2` never blocks. This matters because the `ex_ratatui` runtime is a single GenServer polling the terminal; blocking it freezes rendering and floods queued keystrokes on unblock.

Consequences to preserve when editing the TUI:
- A mode state machine (`:list`, `:input`, `:fetching`, `:loading`, `:videos`, `:playing`) gates which keys do what and which async results are accepted.
- Long-running states accept `Esc` to cancel. Cancel just flips the mode back; the task keeps running but its late result is **dropped by a mode guard** in the matching `handle_info` clause. When adding a new async operation, add both the guarded "still in the right mode" clause and the catch-all that drops stale results.

### Subscriptions and local playlists are never stored with their contents

A subscription persists only the channel URL and name. The video list is fetched live via `Playmark.Channel.list_videos/2` (using `yt-dlp --flat-playlist`) each time a channel is opened, so it's always current. Don't add a videos column or cache.

A local playlist (`Playmark.Playlist`) follows the same rule: it persists only the directory path and its basename as a name. The file list is read live via `Playmark.Local.list_files/1` each time the directory is opened, so it always reflects the current directory contents. Don't store the file list. Unlike subscriptions, local playback (`Playmark.Playback.play_local/1`) skips `yt-dlp` stream resolution — the file path is handed straight to the player for both mpv and vlc — and local files can't be bookmarked (bookmarking goes through oEmbed, which only knows YouTube URLs).

### Title consistency

`yt-dlp --flat-playlist` returns titles in YouTube's default locale, while oEmbed returns the original-language title that bookmarking stores. `Playmark.Channel.enrich_titles/1` re-fetches each flat title via oEmbed in parallel (bounded concurrency + timeout) so the video list matches what a bookmark would save; a failed lookup falls back to the flat title. The same oEmbed lookup also yields the channel name, attached to each video as `:author` (the player's artist metadata — see below); a failed lookup leaves `:author` nil. Resolved titles and authors are memoized in `Playmark.Cache` under `{:title, id}` and `{:author, id}` keys (both effectively immutable), so reopening a channel or repeating a search only issues oEmbed requests for ids not already cached. A failed lookup is not cached.

### Playback player differences

`Playmark.Playback` is a thin facade: it reads config (player, quality, captions), builds a resolved opts map, and dispatches to a backend implementing the `Playmark.Player` behaviour — `Playmark.Player.Mpv` or `Playmark.Player.Vlc`. The behaviour (`play/2`, `play_local/2`, `executable/0`) keeps the two backends in sync at compile time. `Playback` owns only the shared bits: config readers (`player/0`, `format/0`, `subtitles?/0`, `subtitle_lang/0`), `run/2` (shells out, maps exit status to `:ok`/`{:error, reason}`), and `parse_stream_urls/1` (delegated to `Playmark.Player.Vlc`, kept as the historical entry point). The `:playback_impl` seam and its test stub still target `Playmark.Playback` — the split is internal.

`mpv` drives `yt-dlp` itself and is handed the YouTube URL directly (steered to the stream client via `--ytdl-raw-options`). `vlc` can't fetch YouTube pages, so `Playmark.Player.Vlc` pre-resolves stream URLs with `yt-dlp -g` (split video+audio streams are recombined via `--input-slave`). Both force the **stream** client `web_safari` for the video — other clients return signed URLs that yield `HTTP 403`. Preserve this when touching playback.

**Display metadata (title + artist).** A pre-resolved stream URL carries no metadata, so a player falls back to "unknown title / unknown artist" unless we set it. The resolved opts map carries `:title` and `:author` (the channel), threaded from the TUI through `Playback.play/3`/`play_local/3` as a `%{title, author}` meta map. mpv gets `--force-media-title` (it has no artist-override flag, so `:author` is ignored there); VLC gets `--meta-title` and `--meta-artist`. Each flag is omitted when its value is nil/blank. The `:author` source varies by list: bookmarks store `:channel`, enriched channel/search videos carry `:author`, local files have neither; queued items persist `:author` in a DB column so it survives a reload (`item_author/1` in `Playmark.TUI.Actions` normalizes the key).

**Captions need a *second* yt-dlp client, and this is the non-obvious part.** `web_safari` returns fetchable stream URLs but YouTube *discards its caption tracks* without a PO token; the `default` client exposes captions token-free but its stream URLs 403. The two clients are mutually exclusive, so captions can't ride along with stream resolution — a mistake that silently breaks captions on *both* players (this happened once already). Both backends therefore download the caption track out-of-band via `Playmark.Player.Captions.download/2` (uses `subtitle_client`), get back a temp `.vtt`, pass it to the player as `--sub-file`, and delete it after playback (`Captions.cleanup/1` in an `after`). mpv additionally needs `--sid=1` to *select* the external track — yt-dlp/`--sub-file` only makes it available, the player still has to display it. Captions are best-effort: a missing track plays without one, never an error. `mix playmark.debug --subs <url>` diagnoses the whole chain (compares what each client exposes, shows which track the chain selects, runs the real download, prints each player's args).

**The caption track is chosen by a preference chain** (`Captions.select/2`, driven by a single `yt-dlp -J` probe that returns manual tracks, auto tracks, and the video's spoken `language` at once): (1) a *manual* uploader track in `subtitle_default` → (2) else a *manual* track in `subtitle_fallback` (if set) → (3) else the *auto-generated* track in the video's spoken language. Only the winning track is downloaded. Language matching is by prefix, so `en` accepts `en`, `en-US`, `en-orig`. Defaults: captions on, `subtitle_default` = `"en"`, no fallback, auto tier follows the spoken language. `select/2` is a pure function over probe data — test it with synthetic probe maps, not the network.

## Configuration & dependency-injection seams

### User settings (`Playmark.Config`)

`Playmark.Config.load/0` runs once at the top of `Playmark.Application.start/2`. It reads an optional dotenv-style file at `Playmark.Config.path/0` — by default `~/.config/playmark/config.env` (alongside the DB — `Playmark.Application.data_dir/0`), overridable via the `:config_path` app env so tests never touch the user's real file (`config/test.exs` points it at a nonexistent path; `ConfigTest` writes to isolated temp files). It coerces each recognized key and writes it into the `:playmark` app env with `Application.put_env/3`. Recognized keys: `player` (`:mpv`/`:vlc`), `max_height`, `subtitles` (boolean — `true`/`yes`/`on`/`1` vs `false`/`no`/`off`/`0`), `subtitle_default` (string), `subtitle_fallback` (string), `search_limit`, `channel_limit`, `oembed_timeout_ms`, `oembed_concurrency`.

The consuming modules read those keys via `Application.get_env/3`, each passing the built-in default as the fallback — so the default lives at the read site, not in `Playmark.Config`, and a missing file / missing key / invalid value all resolve identically:
- `Playmark.Playback.player/0` → `:player` (default `:mpv`); `Playmark.Playback.format/0` → `:max_height` (default 1080), building the `bestvideo[height<=N]+bestaudio/best` yt-dlp format string; `Playmark.Playback.subtitles?/0` → `:subtitles` (default `true`); `Playmark.Playback.subtitle_default/0` → `:subtitle_default` (default `"en"`) and `subtitle_fallback/0` → `:subtitle_fallback` (default `nil`) feed the caption preference chain. `Mix.Tasks.Playmark.Debug` calls `Playback.format/0` so its diagnostic mirrors real playback.
- `Playmark.Channel` → `:channel_limit` (default 30), `:oembed_timeout_ms` (4000), `:oembed_concurrency` (10).
- `Playmark.Search` → `:search_limit` (default 20).

When adding a user-facing setting: add it to the `@keys` map in `Playmark.Config` with a coercion, and read it with `Application.get_env(:playmark, key, default)` at the use site keeping the current hardcoded value as the default. Invalid values are dropped with a warning (logged during boot, before `Mix.Tasks.Playmark` detaches the console handler). There are no secrets or API keys — don't add a config mechanism aimed at those.

### Test seams

Modules that touch the outside world are swapped in tests via `Application.get_env` seams, defaulting to the real implementation:
- `:playback_impl` (default `Playmark.Playback`)
- `:channel_impl` (default `Playmark.Channel`)
- `:subscriptions_impl` (default `Playmark.Subscriptions`)
- `:metadata_impl` (default `Playmark.Metadata`)
- `:search_impl` (default `Playmark.Search`)
- `:playlists_impl` (default `Playmark.Playlists`)
- `:local_impl` (default `Playmark.Local`)

Tests set these with `Application.put_env` and clean up with `on_exit`, so the suite never spawns a real player or hits the network. Follow this pattern rather than mocking.

## Database

SQLite via `ecto_sqlite3`, single connection (`pool_size: 1` — this is a single-user local app; a larger pool causes a WAL-init race). The production DB lives at `~/.config/playmark/playmark.db`. The path can't be static because it depends on `$HOME`, so `Playmark.Application.start/2` computes and injects it into the Repo config *before* the Repo boots, and creates the directory.

Migrations run automatically on boot **except** in test (`:skip_migrations`), where `test/test_helper.exs` owns setup: it recreates a throwaway `playmark_test.db` and migrates it once. DB tests use `Playmark.DataCase`, which `delete_all`s the tables in `setup` (no SQL sandbox — it fights SQLite's single-writer model) and therefore **must not be `async: true`**.

## Terminal / logging caveat

The TUI owns the terminal, so any log line to stdout/stderr corrupts rendering. `Mix.Tasks.Playmark` detaches the default logger console handler for the TUI session and restores it on exit. Log to a file handler if you need runtime diagnostics while the TUI is up.
