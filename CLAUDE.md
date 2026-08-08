# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

playmark is a terminal UI (Elixir + `ex_ratatui`) for bookmarking YouTube videos, subscribing to channels, and searching YouTube, then playing videos in an external player — all without a YouTube API key. Metadata comes from YouTube's public oEmbed endpoint; channel listings, search, and stream resolution shell out to `yt-dlp`; playback hands off to `mpv`, `vlc`, or `ffplay`.

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

The app requires `yt-dlp` and one media player (`vlc` by default, or `mpv`/`ffplay`) on the `PATH`. `Mix.Tasks.Playmark` loads user configuration before `Playmark.SystemCheck` verifies the executables and exits with install hints if any are missing. It only requires the *configured* player, not all three.

## Architecture

Layers, outermost to innermost:

- **`Playmark.TUI`** — the `ex_ratatui` app shell. Owns the runtime callbacks (`mount/1`, `handle_event/2`, `handle_info/2`, `render/2`) and delegates:
  - **`Playmark.TUI.Actions`** — the **browse core**'s state transitions: the list / videos / channel-playlists / filter / input / local-browse key handlers, navigation, and their task spawners. This is one state machine, not several — `close_channel_playlists/1` writes 12 keys spanning what look like three separate concerns — so it is deliberately not split further. It keeps `current_list/1` and `selected_item/1` private, which is why the key-handler bodies that read the browse cursor (`play_selected/1`, `enqueue_selected/2`, `bookmark_selected_video/1`) stay here and call *out* to the modules below.
  - **`Playmark.TUI.PlaybackActions`** — `start_play/4` (the single funnel every play routes through, and where history is written), the resume prompt, and the `stream_plan/2` / `captions_plan/2` / `play_steps/2` step list.
  - **`Playmark.TUI.QueueActions`** / **`HistoryActions`** — the two modals that store *content*: `enqueue/4` (the enqueue funnel) and the queue-manage modal; the watch-history modal and its replay/prune keys.
  - **`Playmark.TUI.SearchActions`** / **`ExploreActions`** — the two transient overlays. Both open over any browse mode and terminate their task on cancel; Search additionally owns a query sub-machine and its own filter term.
  - **`Playmark.TUI.AddActions`** — the two ways a row enters the DB: `start_add/2` (from the input field, dispatching on `state.view`) and `bookmark_video/2` (from a video row).
  - **`Playmark.TUI.HelpActions`** — the static `:help` overlay.
  - **`Playmark.TUI.Nav`** — pure cursor/list helpers shared by every mover: `page_step/0`, `clamp/3`, `clamp_index/2`, `jump_index/2`, `playable_video/1`, `item_author/1`.
  - **`Playmark.TUI.Impl`** — the ten `Application.get_env` test seams in one place (see *Test seams* below). Not every call to those modules belongs here: the delete paths and `Playback`'s config reads deliberately bypass it — read that module's doc before routing a new call through it.
  - **`Playmark.TUI.Filter`** — pure list filtering, shared with `Actions` (see *The list filter* below).
  - **`Playmark.TUI.View`** — pure `state -> [{widget, rect}]` rendering, no side effects.

  The overlay modules own only their own state keys. `:selected`, `:filter`, `:videos`, `:channel_name`, `:channel_url`, `:videos_return`, and `:local_*` are read/written by `Actions` and `Filter` only; `:mode` and `:view` are shared reads. Hold that invariant when adding a handler:

  ```sh
  grep -nE 'state\.(selected|videos|filter|channel_name|channel_url|local_)' \
    lib/playmark/tui/*_actions.ex   # expect zero hits
  ```
- **Contexts** (`Playmark.Bookmarks`, `Playmark.Subscriptions`, `Playmark.Playlists`, `Playmark.Locals`) — Ecto-backed CRUD over their singular schemas. `Playlists` means saved YouTube playlists; `Locals` means registered filesystem directories. Playlist and subscription contents are fetched live rather than persisted.
- **`Playmark.YouTube`** — permissive host validation plus source-specific canonicalization. `canonical_channel_url/1` strips trailing channel-tab segments. `canonical_playlist_url/1` requires `list=` and normalizes direct and watch links to one playlist URL.
- **External-IO modules** (`Playmark.Metadata`, `Playmark.Channel`, `Playmark.Search`, `Playmark.Explore`, `Playmark.YouTubePlaylist`, `Playmark.LocalFiles`, `Playmark.Playback` + its player backends) — the oEmbed / `yt-dlp` / filesystem / player boundary. `YouTubePlaylist` reads bounded flat playlist metadata and entries; `LocalFiles.list_entries/1` reads one folder's child directories and media files. Both return tagged results without blocking the TUI process.
- **`Playmark.Cache`** — a generic ETS-backed key/value cache owned by a GenServer in the supervision tree (`Playmark.Application`). Reads (`get/1`) run directly against a public, read-optimized ETS table from the calling process — including `Task.async_stream` children — while writes (`put/2`, a cast) funnel through the GenServer so the size cap is enforced in one place. The cap is crude: at `@max_entries` it drops the whole table rather than track an LRU. Only memoize values that are effectively immutable or where a stale read is harmless; do **not** cache anything that must stay live (e.g. a channel's video set). Its one current user is title enrichment (see below).

### The non-blocking task model (central to the TUI)

Anything that shells out, hits the network, reads a directory, or runs playback executes in a spawned `Task` that sends its result back to the runtime process via a message handled in `Playmark.TUI.handle_info/2`. `handle_event/2` never blocks. This matters because the `ex_ratatui` runtime is a single GenServer polling the terminal; blocking it freezes rendering and floods queued keystrokes on unblock.

Consequences to preserve when editing the TUI:
- The base mode state machine is supplemented by a non-playable channel-playlist level (`:channel_playlists_loading`, `:channel_playlists`, `:channel_playlists_filter`), isolated Search (`:search_input`, `:search_loading`, `:search_results`, `:search_filter`), and Explore modes. Search and Explore can open over base lists, videos, or channel playlist containers. Queue and History may open over these browse modes and return to them.
- A static `:help` overlay (`?` from any browse mode, excluding `:help` itself so a second `?` closes it) mirrors the Queue/History open/close/return shape: `HelpActions.open_help/1` sets `mode: :help` + `help_return: state.mode`, and `handle_help_key/2` restores `help_return` on `Esc`/`?`. It spawns no task and reads no state — `View.help_body/0`/`help_text/0` is a hand-authored keybinding reference kept in lockstep with the handlers (footers only surface a mode's most relevant keys).
- Every browse-list mover (`move/2`, `move_channel_playlist/2`, `move_queue/2`, `move_history/2`, `move_explore/2`, `move_search/2` — each private to the module that owns its list) accepts an integer delta *or* a `:top`/`:bottom` jump target resolved by the shared `Nav.jump_index/2`. `g`/`Home` → `:top`, `G`/`End` → `:bottom`, `PageUp`/`PageDown` → `±Nav.page_step()` (fixed step, `@page_step 10` in `Playmark.TUI.Nav` — there is no terminal-height value in TUI state, so paging is a fixed step, not a real screenful; `Nav.clamp/3` bounds the ends). Every mode's key handler wires these six codes.
- Fetching and loading states accept `Esc` to cancel; playback instead returns when the external player closes. Search, Explore, local-directory reads, channel-tab loads, channel playlist discovery, and playlist-video loads terminate tracked tasks and invalidate per-request references. Older add paths still drop late results through mode guards.
- Transient footer statuses self-clear. `Playmark.TUI.subscriptions/1` is declared purely as a function of state — a set `:status` arms a one-shot `ExRatatui.Subscription.once` timer (`@status_clear_ms`, 5s), a nil status disarms it — and the runtime reconciles it after every transition. The `{:clear_status, status}` message carries the status it was armed for: `handle_info` only clears when it still matches (so a newer status isn't clobbered), and because the runtime diffs subscriptions by their fields, a changed status forces a fresh timer with its own full window.

### The list filter (`:filter` mode)

`/` opens an incremental filter over every browse list — bookmarks, subscriptions, playlists, locals, ordinary `:videos` lists, channel playlist containers, and Search results. Search and channel playlists use separate filter/cursor fields so nested navigation preserves the underlying page.

Filtering is a pure in-memory substring match. Match fields per view: bookmarks `[:title, :channel]`, subscriptions `[:name, :url]`, playlists `[:title, :channel]`, locals `[:name, :path]`, videos `[:title]`.

The ordinary term lives in `state.filter` with `filter_return` remembering `:list` or `:videos`. Search mirrors this with `search_filter`/`search_selected`; channel playlist containers use `channel_playlist_filter`/`channel_playlist_selected`. Navigation, rendering, and actions resolve through the same pure filter helper for their respective list.

### Live source contents

A subscription persists only the canonical channel URL and name. `Playmark.Channel.list_videos/2` fetches playable Videos/Streams rows; `Playmark.Channel.list_playlists/1` fetches non-playable playlist containers from `/playlists`. In direct channel video modes, `v`/`s` switch playable tabs and `p` opens the playlist-container level. There, `Enter` loads the selected container through `Playmark.YouTubePlaylist.list_videos/1`, while contextual `p` persists that resolved container through `Playlists.save_playlist/2`. Nested playlist videos set `videos_return: :channel_playlists`, so Esc restores the preserved parent rows/cursor/filter. Discovered containers remain transient unless explicitly saved.

Each video map also carries `:duration` (runtime in seconds) and `:views` (view count), both integers or `nil`, parsed by `Channel.parse_videos/1` from the `%(duration)s`/`%(view_count)s` fields that ride along in the same fast `--flat-playlist` call (no per-video probe). `Playmark.TUI.View` renders these as **Duration** and **Views** columns on the playable YouTube lists — the ordinary `:videos` list (channel uploads and playlist entries), Search results, and Explore — via the shared `video_row/1` helper (`format_duration/1` → `M:SS`/`H:MM:SS`, `format_views/1` → compact `4M`/`12K`, blank on `nil`). The Streams tab keeps its Title/Status layout and Locals keep Name/Type; a source that omits a field (or an older cached row shape) renders a blank cell, never a crash.

Each video map carries a `:live` tag — `:live` / `:ended` / `:upcoming` / `:none` — parsed from yt-dlp's `%(live_status)s` field by `Channel.parse_videos/1`. That parser is shared with `Playmark.Search`, so the two callers' `--print` templates and the parser must stay in lockstep; the template is `id / title / live_status / duration / view_count`, and the parser tolerates shorter lines (a 3-field status-only line, or a legacy 2-field line) by defaulting the absent fields to `:none`/`nil`. `enrich_titles/1` preserves `:live`, `:duration`, and `:views` (it only overwrites `:title`/`:author`). `Explore` and `YouTubePlaylist` have their own parsers that carry the same `:duration`/`:views` fields (each with a private `parse_int/1`). Live playback needs no special handling — a live URL flows through the normal play path and joins at the live edge (no `--live-from-start`).

A saved playlist (`Playmark.Playlist`) persists only its canonical URL, title, and channel. It may be added by URL through `Playlists.add_playlist/1` or directly from a discovered channel container through `Playlists.save_playlist/2`. `Playmark.YouTubePlaylist.list_videos/2` fetches up to `playlist_limit` current entries in source order each time it opens.

A local (`Playmark.Local`) persists only a root directory path and basename. `Playmark.LocalFiles.list_entries/1` reads one folder at a time, returning real child directories before supported media files in natural filename order; child directory symlinks are omitted. Local folders reuse `:videos`, while a transient stack preserves each parent's path, rows, cursor, and filter. `r` rereads only the current frame through the tracked local request and restores its filter and selected entry ID; failed reads keep cached rows and never remove the persisted registration. Local playback skips yt-dlp stream resolution, and local files cannot be bookmarked.

The **queue** (`Playmark.Queue`) and **history** (`Playmark.History`) are the deliberate opposite: they store *content* outright, because it can't be re-derived from a handle. The queue persists user-curated items with an explicit `position`; history persists a log of what was played. Each row carries the source-agnostic `%{title, url, author, local}` fields the play path needs (the `local` flag forks `play/2` vs `play_local/2`), so a queued/history item replays without re-fetching. History is written from `Playmark.TUI.PlaybackActions.start_play/4` — the single funnel every play routes through — after any resume choice and immediately before the playback task starts. Rewatching *upserts* on a unique index on `:url` (bumps `played_at`, refreshes title/author) rather than adding a duplicate row — the deliberate opposite of `queue_items`, which allows duplicates. History is unbounded (no retention cap). Its nullable `resume_position_ms`/`duration_ms` fields are updated independently of `played_at`; mpv and VLC checkpoint finite, seekable media, while ffplay and live media do not.

`Queue.enqueue/1` tail-appends at `max(position)+1`; `Queue.enqueue_next/1` appends then promotes the new row to index 1 (just after the head) by walking `move_up/1` until it sits there — reuses the existing `swap/2` rather than computing a between-position, because `position` is a plain integer with no unique constraint and no contiguity guarantee. `e` → `enqueue/1` (tail), `n` → `enqueue_next/1` (play next) everywhere `e` works, including the History overlay. History items carry their own `local` flag so the play path forks correctly without re-deriving it.

### Title consistency

`yt-dlp --flat-playlist` returns titles in YouTube's default locale, while oEmbed returns the original-language title that bookmarking stores. `Playmark.Channel.enrich_titles/1` re-fetches each flat title via oEmbed in parallel (bounded concurrency + timeout) so the video list matches what a bookmark would save; a failed lookup falls back to the flat title. The same oEmbed lookup also yields the channel name, attached to each video as `:author` (the player's artist metadata — see below); a failed lookup leaves `:author` nil. Resolved titles and authors are memoized in `Playmark.Cache` under `{:title, id}` and `{:author, id}` keys (both effectively immutable), so reopening a channel or repeating a search only issues oEmbed requests for ids not already cached. A failed lookup is not cached.

### Playback player differences

`Playmark.Playback` is a thin facade: it reads config (player, quality, captions), builds a resolved opts map, and dispatches to a backend implementing the `Playmark.Player` behaviour — `Playmark.Player.Mpv`, `Playmark.Player.Vlc`, or `Playmark.Player.Ffplay`. The behaviour (`play/2`, `play_local/2`, `executable/0`) keeps the backends in sync at compile time. mpv and VLC launch through `Playmark.Player.Control`, which owns the Port lifecycle, connects to a unique local control socket, throttles position checkpoints, and returns `:completed`, `:stopped`, or `:unknown`; ffplay remains on the simpler blocking `Playback.run/2` path because it has no stable control API. mpv gets exact JSON IPC properties/end reasons. VLC is polled through RC and classifies completion by the final position's distance from the known duration. The `:playback_impl` seam and its test stub still target `Playmark.Playback` — the split is internal.

`mpv` drives `yt-dlp` itself and is handed the YouTube URL directly (steered to the stream client via `--ytdl-raw-options`). `vlc` can't fetch YouTube pages, so `Playmark.Player.Vlc` pre-resolves stream URLs with `yt-dlp -g` (split video+audio streams are recombined via `--input-slave`). Both force the **stream** client `web_safari` for the video — other clients return signed URLs that yield `HTTP 403`. Preserve this when touching playback.

`ffplay` (from FFmpeg, usually already present via yt-dlp's dependency) is the minimal, no-extra-install tier. Like VLC it pre-resolves with `yt-dlp -g` and forces `web_safari`, but two things it deliberately can't do shape `Playmark.Player.Ffplay`: it has no `--input-slave`, so it forces a **single muxed** format (`best[height<=N]`, not the split `bestvideo+bestaudio/best`) and takes the first URL; and it has no clean `--sub-file` sidecar, so it **skips captions entirely** (the `subtitles?`/`subtitle_*` opts are accepted but ignored). Metadata is `-window_title` only (no artist concept, so `:author` is ignored, as with mpv). Its testable arg-builder is `play_args/2`.

**Display metadata (title + artist).** A pre-resolved stream URL carries no metadata, so a player falls back to "unknown title / unknown artist" unless we set it. The resolved opts map carries `:title` and `:author` (the channel), threaded from the TUI through `Playback.play/3`/`play_local/3` as a `%{title, author}` meta map. mpv gets `--force-media-title` (it has no artist-override flag, so `:author` is ignored there); VLC gets `--meta-title` and `--meta-artist`; ffplay gets `-window_title` only (no artist concept, `:author` ignored). Each flag is omitted when its value is nil/blank. The `:author` source varies by list: bookmarks store `:channel`, enriched channel/search videos carry `:author`, local files have neither; queued items persist `:author` in a DB column so it survives a reload (`item_author/1` in `Playmark.TUI.Nav` normalizes the key).

**Captions need a *second* yt-dlp client, and this is the non-obvious part.** `web_safari` returns fetchable stream URLs but YouTube *discards its caption tracks* without a PO token; the `default` client exposes captions token-free but its stream URLs 403. The two clients are mutually exclusive, so captions can't ride along with stream resolution — a mistake that silently breaks captions on the caption-capable players (this happened once already). The mpv and VLC backends therefore download the caption track out-of-band via `Playmark.Player.Captions.download/2` (uses `subtitle_client`), get back a temp `.vtt`, pass it to the player as `--sub-file`, and delete it after playback (`Captions.cleanup/1` in an `after`). mpv additionally needs `--sid=1` to *select* the external track — yt-dlp/`--sub-file` only makes it available, the player still has to display it. (`ffplay` opts out of this chain entirely — it has no clean sidecar flag, so it never fetches captions.) Captions are best-effort: a missing track plays without one, never an error. `mix playmark.debug --subs <url>` diagnoses the whole chain (compares what each client exposes, shows which track the chain selects, runs the real download, prints each player's args).

**The caption track is chosen language-first, quality-second** (`Captions.select/2`, driven by a single `yt-dlp -J` probe that returns manual tracks, auto tracks, and the video's spoken `language` at once): (1) a *manual* track in `subtitle_default` → (2) else a *translation* into `subtitle_default` → (3) else a *manual* track in `subtitle_fallback` (if set) → (4) else a *translation* into `subtitle_fallback` → (5) else the *auto-generated* track in the video's spoken language. Tiers 2 and 4 are skipped when `subtitle_translate` is false. Listing two languages ranks them, so a translation into the first beats a human track in the second — the earlier ordering (both manual tiers before any translation) made `subtitle_default` unreachable for a user whose fallback the uploader happened to provide. Only the winning track is downloaded. Language matching is by prefix, so `en` accepts `en`, `en-US`, `en-orig`. Defaults: captions on, `subtitle_default` = `"en"`, no fallback, translation accepted, auto tier follows the spoken language. `select/2` is a pure function over probe data — test it with synthetic probe maps, not the network.

**Translations come in two shapes, and the manual-source one is easy to miss.** YouTube exposes translations as ordinary `automatic_captions` entries, keyed two ways: a *plain* key (`id`) translates the ASR transcript (two lossy passes), while a `{target}-{source}` key (`id-en` = "Indonesian from English") translates *that uploader track* (one pass, human-written source) — the same thing the web player's "auto-translate" does to a manual track. `source_rank/3` prefers an uploader source in a language the user listed, then any uploader source, then the transcript. yt-dlp only emits `{target}-{source}` keys when `--write-auto-subs` is passed (it gates them behind that flag — "Constructing the full subtitle dictionary is slow", `youtube/_video.py`), so `probe/2` passes it *on a `--skip-download` probe*: without it a Korean podcast with manual `en`/`ko` reports 2 auto keys instead of 314 and no translation is reachable. Cost is JSON size (~143 KB → ~1.2 MB), not time. `auto_kind/2` classifies a `{target}-{source}` key as `:translated` even when its target matches the spoken language, but only when the suffix names a real manual track — so a plain regional variant like `en-US` is still `:auto`.

Tier 3 exists because YouTube's `automatic_captions` map is not just the spoken language: it lists the same ASR transcript machine-translated into ~150 target languages, each an ordinary track key downloadable through the *same* `--write-auto-subs --sub-langs <key>` call (no extra request, no different client). Without it, a request for `en` on a Korean video yields a Korean transcript. Such a track is tagged `{:translated, key}` rather than `{:auto, key}` — it's a translation *of* a speech-recognition transcript, two lossy passes, and `View.caption_detail/1` labels it "auto-translated" so a bad caption is attributable. A track in the requested language that *is* the spoken language is native, so it keeps the `:auto` tag; an unknown spoken language can't be shown native and reports as `:translated`. Because nearly every video offers every target language, tier 3 would make tier 4 unreachable — hence `subtitle_translate` (default `true`) to turn it off for users who want the original transcript. Adding a kind to this chain means touching five places: `select/2`, `View.caption_detail/1`, `show_selection/2` in `Mix.Tasks.Playmark.Debug` (a bare `case` — an unhandled kind raises), the `captions_plan/2` comment in `TUI.PlaybackActions`, and the tests.

The same `-J` probe also carries a top-level `"chapters"` array. `Captions.chapters/1` (pure, beside `select/2`) counts it; `report_chapters/2` (mirroring `report_selection/2`) fires `{:chapters, count}` through `opts.progress` after the selection report. `handle_info` in `Playmark.TUI` folds it into `playing.chapters` (seeded `nil`), and `View.chapters_detail/1` renders it in the Now Playing panel when non-nil and non-zero. Best-effort / display-only: the count appears only when the caption probe runs (mpv or VLC with captions on); ffplay and captions-off play without it, never an error.

## Configuration & dependency-injection seams

### User settings (`Playmark.Config`)

`Playmark.Config.load/0` runs once at application startup and loads the optional `~/.config/playmark/config.env`. Recognized limits include `search_limit`, `explore_limit`, `playlist_limit`, and `channel_limit`, alongside playback, subtitle, oEmbed-enrichment (`oembed_timeout_ms`, `oembed_concurrency`), and socket-timeout settings.

The consuming modules read those keys via `Application.get_env/3`, each passing the built-in default as the fallback — so the default lives at the read site, not in `Playmark.Config`, and a missing file / missing key / invalid value all resolve identically:
- `Playmark.Playback.player/0` → `:player` (the shipped config selects `:vlc`; the reader falls back to `:mpv` only when unset); `Playmark.Playback.format/0` → `:max_height` (default 1080), building the `bestvideo[height<=N]+bestaudio/best` yt-dlp format string; `Playmark.Playback.subtitles?/0` → `:subtitles` (default `true`); `Playmark.Playback.subtitle_default/0` → `:subtitle_default` (default `"en"`), `subtitle_fallback/0` → `:subtitle_fallback` (default `nil`), and `subtitle_translate/0` → `:subtitle_translate` (default `true`) feed the caption preference chain. `Mix.Tasks.Playmark.Debug` calls `Playback.format/0` so its diagnostic mirrors real playback.
- `Playmark.Channel` → `:channel_limit` (default 30 rows per Videos, Streams, or Playlists tab), `:oembed_timeout_ms` (4000), `:oembed_concurrency` (10).
- `Playmark.Search` → `:search_limit` (default 20).
- `Playmark.Explore` → `:explore_limit` (default 20).
- `Playmark.YouTubePlaylist` → `:playlist_limit` (default 100).
- `:socket_timeout` (default 30, seconds) is passed to `yt-dlp --socket-timeout` by `Playmark.Channel`, `Playmark.Search`, `Playmark.Explore`, `Playmark.YouTubePlaylist`, `Playmark.Player.Vlc`, `Playmark.Player.Ffplay`, and `Playmark.Player.Captions`. It bounds each socket read/connect so a black-holed network can't hang a call forever. Most TUI cancellation paths only drop a late result; Search and Explore additionally terminate tracked tasks. (`Playmark.Metadata`'s direct oEmbed fetch bounds itself separately with `receive_timeout: 4000` + `retry: false`.)

When adding a user-facing setting: add it to the `@keys` map in `Playmark.Config` with a coercion, and read it with `Application.get_env(:playmark, key, default)` at the use site keeping the current hardcoded value as the default. Invalid values are dropped with a warning (logged during boot, before `Mix.Tasks.Playmark` detaches the console handler). There are no secrets or API keys — don't add a config mechanism aimed at those.

### Test seams

Modules that touch the outside world are swapped in tests via `Application.get_env` seams, defaulting to the real implementation:
- `:playback_impl` (default `Playmark.Playback`)
- `:channel_impl` (default `Playmark.Channel`)
- `:subscriptions_impl` (default `Playmark.Subscriptions`)
- `:metadata_impl` (default `Playmark.Metadata`)
- `:search_impl` (default `Playmark.Search`)
- `:explore_impl` (default `Playmark.Explore`)
- `:playlists_impl` (default `Playmark.Playlists`)
- `:locals_impl` (default `Playmark.Locals`)
- `:youtube_playlist_impl` (default `Playmark.YouTubePlaylist`)
- `:local_files_impl` (default `Playmark.LocalFiles`)
- `:history_impl` (default `Playmark.History`)

Tests set these with `Application.put_env` and clean up with `on_exit`, so the suite never spawns a real player or hits the network. Follow this pattern rather than mocking.

## Database

SQLite via `ecto_sqlite3`, single connection (`pool_size: 1` — this is a single-user local app; a larger pool causes a WAL-init race). The production DB lives at `~/.config/playmark/playmark.db`. The path can't be static because it depends on `$HOME`, so `Playmark.Application.start/2` computes and injects it into the Repo config *before* the Repo boots, and creates the directory.

Migrations run automatically on boot **except** in test (`:skip_migrations`), where `test/test_helper.exs` owns setup: it recreates a throwaway `playmark_test.db` and migrates it once. DB tests use `Playmark.DataCase`, which `delete_all`s the tables in `setup` (no SQL sandbox — it fights SQLite's single-writer model) and therefore **must not be `async: true`**.

## Terminal / logging caveat

The TUI owns the terminal, so any log line to stdout/stderr corrupts rendering. `Mix.Tasks.Playmark` detaches the default logger console handler for the TUI session and restores it on exit. Log to a file handler if you need runtime diagnostics while the TUI is up.
