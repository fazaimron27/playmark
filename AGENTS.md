# AGENTS.md

## Commands

- Requires Elixir 1.18+/OTP 26+. Install with `mix deps.get`.
- Run all tests with `mix test`; focus with `mix test test/path_test.exs` or `mix test test/path_test.exs:LINE`.
- Before finishing, run `mix format`, `mix compile --warnings-as-errors`, then `mix test`. There is no separate lint, typecheck, codegen, or CI command.
- Launch with `mix playmark`; this requires `yt-dlp` plus only the configured player (`vlc` by default, `mpv`, or `ffplay`) on `PATH`.
- Diagnose outside the terminal UI with `mix playmark.debug <url>`, `--subs <url>`, `--play <url>`, or `--mem [channel-url]`; normal TUI logging is intentionally hidden.

## Execution Model

- `Playmark.Application` loads `~/.config/playmark/config.env`, injects the runtime SQLite path, starts `Repo` and `Cache`, then auto-migrates. `Mix.Tasks.Playmark` performs executable checks and starts `Playmark.TUI`.
- Each directory under `lib/playmark/` holds one kind of module and matches its namespace: `tui/` (shell, actions, view), `source/` (oEmbed/yt-dlp/filesystem reads), `player/` (the playback facade and backends), and one directory per Ecto context holding its schema (`bookmarks/bookmark.ex`, `queue/item.ex`). Add a new file beside its own kind; a new kind means a new directory, not another module in the root.
- `Playmark.TUI` owns runtime callbacks and the browse-core result handlers, `TUI.Actions` owns the browse-core transitions/task spawning (with the overlays in sibling `TUI.*Actions` modules, plus `TUI.Nav`, `TUI.Status`, and `TUI.Impl`), and `TUI.View` is pure rendering. Keep network, shell, filesystem, and playback work out of `handle_event/2`: spawn a task and commit its message in `handle_info/2`.
- An overlay owns both halves of its own message: the spawn and the `handle_result/2` that commits it. `handle_info/2` matches the tag and forwards the whole tuple, stale-ref clause included. Put a new overlay handler with its spawn, not in the shell; a listing that writes browse-core keys stays in the shell.
- Search, Explore, local-directory, channel-tab, channel-playlist, and playlist-video requests track both a task PID and request ref. Cancellation kills the task and clears the ref; result handlers must reject stale refs. Older add paths are untracked and discard late messages through mode guards.
- Search/Explore/Queue/History are overlays that must restore the exact underlying browse mode. Ordinary videos, Search results, and channel playlist containers intentionally keep separate rows, cursors, and filters.
- Local folders reuse `:videos`; each parent frame preserves path, rows, cursor, and filter. `r` refreshes only the current frame and preserves its filtered selection by entry ID. Directory entries are non-playable and non-queueable, and child directory symlinks are intentionally omitted.
- Footer expiry is declarative: `TUI.subscriptions/1` arms the one-shot timer and `{:clear_status, status}` only clears the matching status. Do not add ad-hoc status timers.
- `Source.Channel` and `Source.Search` share `Source.Channel.parse_videos/1`; keep their yt-dlp `--print` field order in lockstep, including `live_status`.
- `Cache` is ETS-backed and clears the whole table at its cap. Cache only effectively immutable data; never cache live channel/playlist contents.

## Data And Tests

- Subscriptions, saved playlists, and locals persist handles only; their contents are fetched fresh. A missing local path never removes its registration. Queue and history persist complete playable items. Queue duplicates are valid; history URL uniqueness supports upsert.
- Production uses `~/.config/playmark/playmark.db`, WAL, and `pool_size: 1`; increasing the pool can reintroduce the SQLite WAL initialization race.
- Tests recreate `playmark_test.db` and migrate it once in `test/test_helper.exs`; application startup skips migrations in test.
- Database cases use `Playmark.DataCase` and must not be async. It clears tables directly instead of using SQL Sandbox; add every new persisted schema to its cleanup.
- Tests must not contact YouTube or launch players. Replace external I/O through the existing `Application.get_env` implementation seams and restore overrides in `on_exit`; seams are scoped: for example, `:metadata_impl` controls channel enrichment, while bookmark creation calls `Playmark.Source.Metadata` directly, and `TUI.mount/1` reads real persisted contexts.
- Add schema changes as new timestamped migrations; startup auto-runs migrations, so do not edit one that may already have run in a user's database.

## Playback

- Do not merge the yt-dlp clients: streams must use `web_safari` (fetchable URLs), while captions must be probed/downloaded separately with `default` (caption tracks without a PO token).
- mpv receives the YouTube URL and drives yt-dlp; downloaded captions require both `--sub-file` and `--sid=1`. VLC pre-resolves with `yt-dlp -g` and joins split audio through `--input-slave`. ffplay forces one muxed `best[height<=N]` stream and intentionally skips captions.
- Caption selection is language-first, quality-second: manual `subtitle_default`, then a translation into it, then manual `subtitle_fallback`, then a translation into that, then auto captions in the spoken language. Translation tiers are skipped when `subtitle_translate = false`. Do not restore the old both-manual-tiers-first order — it made `subtitle_default` unreachable whenever the uploader supplied the fallback language.
- Translations arrive as `automatic_captions` entries under two key shapes: plain (`id`, translating the ASR transcript) and `{target}-{source}` (`id-en`, translating that uploader track — better, since the source is human-written). `probe/2` must keep passing `--write-auto-subs` even though it downloads nothing: yt-dlp gates `{target}-{source}` keys behind that flag, and without it such videos expose no translations at all. `auto_kind/2` treats a `{target}-{source}` key as `:translated` only when the suffix names a real manual track, so regional variants like `en-US` stay `:auto`.
- A translated track is tagged `:translated`, not `:auto`, so the UI can name the rougher tier. Captions are best-effort; clean temporary VTT files in `after` and test `Captions.select/2` with synthetic probe maps, not the network.

## Configuration And Terminal

- For a user setting, add its coercion to `Playmark.Config.@keys`, read it at the use site with `Application.get_env/3` and a built-in fallback, document it, and extend config tests/restoration. Defaults live at consumers, not in the loader.
- The TUI owns stdout/stderr; console logging corrupts rendering. `Mix.Tasks.Playmark` removes the default Logger handler for the session, so use the debug task or a file handler for runtime diagnosis.
- When asked to commit, follow the repository's Conventional Commit subjects, including scopes where useful (for example, `feat(tui): ...`, `test(history): ...`, or `docs: ...`).
- `CLAUDE.md` contains deeper subsystem rationale, but executable code is authoritative when it differs.
