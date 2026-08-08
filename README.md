# playmark

A terminal UI for playing video without leaving your terminal — bookmark
YouTube videos, subscribe to channels, save playlists, search or explore YouTube,
and browse local directories, then play any of it in your media player. Metadata is
fetched without any API key (via the public oEmbed endpoint), streams are
resolved with `yt-dlp`, and playback hands off to `vlc`, `mpv`, or `ffplay`.

## Requirements

- Elixir 1.18+ / Erlang OTP 26+
- [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) on your `PATH`
- A media player on your `PATH`: [`vlc`](https://www.videolan.org/vlc/) (default),
  [`mpv`](https://mpv.io), or [`ffplay`](https://ffmpeg.org/ffplay.html)

playmark checks for `yt-dlp` and the configured player on startup and exits with
a helpful message if either is missing.

## Setup

```sh
mix deps.get
mix compile
```

The SQLite database lives at `~/.config/playmark/playmark.db`. The directory and
schema are created automatically on first run.

## Configuration

playmark needs no API key and stores no secrets. A few settings can be changed
without editing any Elixir source by creating a file at
`~/.config/playmark/config.env` — the same directory as the database. It's a
plain `key = value` file; `#` starts a comment, blank lines are ignored, and any
key you leave out keeps its default. The file is optional: with no file, every
setting uses its default.

```sh
# ~/.config/playmark/config.env
player = vlc              # vlc (default), mpv, or ffplay
max_height = 1080         # cap playback resolution (video height in pixels)
subtitles = true          # show captions (default true)
subtitle_default = en     # first-choice caption language (default en)
subtitle_fallback = id    # second-choice language (optional, no default)
subtitle_translate = true # accept machine-translated captions (default true)
search_limit = 20         # results per YouTube search
explore_limit = 20        # cards fetched from YouTube's homepage
playlist_limit = 100      # videos fetched when opening a playlist
channel_limit = 30        # rows fetched from a channel tab
oembed_timeout_ms = 4000  # per-title metadata lookup timeout
oembed_concurrency = 10   # parallel metadata lookups
socket_timeout = 30       # yt-dlp per-socket timeout, seconds
```

Settings are read at startup, so restart playmark after editing the file. An
unknown key or an invalid value is skipped (with a warning at launch) and the
default stands, so a typo won't stop the app from starting.

### Choosing a player

Playback defaults to VLC. Set `player = mpv` to let mpv drive `yt-dlp` itself and
handle HLS/muxing natively. VLC and ffplay cannot fetch YouTube pages, so playmark
resolves stream URLs with `yt-dlp -g` first. ffplay uses one muxed stream and does
not support playmark's downloaded YouTube captions or playback resume tracking.
mpv and VLC track seekable videos and local files through their control sockets.

## Usage

Launch the TUI:

```sh
mix playmark
```

The TUI has four views — **Bookmarks**, **Subscriptions**, **Playlists**, and
**Locals** — cycled with `Tab`.

From any view or open video list, press `S` to open **Search**, `E` to open
**Explore**, `Q` to manage the queue, or `H` to view watch history. Press `?`
for a keybinding reference overlay (`Esc` or `?` closes it).

Every list supports the same navigation keys: `j`/`k` (or arrow keys) move one
row, `g`/`Home` jump to the top, `G`/`End` to the bottom, and `PageUp`/`PageDown`
move by a fixed step.

Bookmarks view:

- `j` / `k` (or arrow keys) — move the selection
- `a` — add a bookmark: type/paste a YouTube URL, `Enter` fetches its title and
  channel and saves it, `Esc` cancels
- `d` — delete the selected bookmark (`y` confirms, any other key cancels)
- `Enter` — play the selected video in the configured player
- `/` — filter the list (see [Filtering](#filtering))
- `Tab` — cycle to subscriptions
- `q` — quit

Subscriptions view: subscribe to a channel and browse its Videos, Streams, and
Playlists tabs live. Channel contents are fetched fresh with
`yt-dlp --flat-playlist` and never stored, so they stay current.

- `a` — add a subscription: paste a channel URL (e.g.
  `https://www.youtube.com/@handle`), `Enter` resolves the channel name
  and saves it. A pasted tab suffix (`/videos`, `/streams`, `/shorts`, …) is
  stripped, so `.../@handle/videos` and `.../@handle` are the same subscription
- `d` — unsubscribe from the selected channel (`y` confirms, any other key cancels)
- `Enter` — open the channel and list its latest videos
- `/` — filter the list (see [Filtering](#filtering))
- `Tab` — cycle to playlists

Inside a channel:

- `v` / `s` — show the channel's Videos or Streams; these rows are directly
  playable. Videos show **Duration** and **Views** columns; Streams instead
  include `LIVE`, `ENDED`, or `SOON` status badges
- `p` — show the channel's playlist containers; these are not directly playable
- `Enter` on a playlist container — fetch and show that playlist's videos
- `p` on a playlist container — save it to Playmark's top-level Playlists view
- `Esc` from playlist videos — return to the channel's playlist containers;
  `Esc` again returns to Subscriptions

Search overlay: query YouTube directly without leaving the current page or using
an API key.

- `S` — open Search from a view or open video list; from results, start a new query
- `Enter` — submit the query or play the selected result
- `b` / `e` — bookmark or queue the selected result
- `n` — queue the selected result to play next (right after the current item)
- `/` — filter the current results locally
- `Q` / `H` — open Queue or History, returning to Search when closed
- `Esc` — cancel a running search; in results, clear an active filter first, then
  return to the underlying page

Search keeps its own rows, cursor, and filter, so opening it over Locals still
treats results as YouTube videos and closing it restores the original list and
filter. Search and Explore are sibling overlays and do not open over each other.
Results follow YouTube's relevance ranking (not strictly date-sorted).

Playlists view: save a YouTube playlist and browse its current videos. Only the
canonical playlist URL, title, and channel are stored; entries are fetched live
with `yt-dlp --flat-playlist` whenever the playlist is opened. Equivalent direct
and `watch?...&list=...` links normalize to one saved playlist.

- `a` — add a playlist URL, resolving and saving its title and channel
- `d` — remove the selected saved playlist (`y` confirms)
- `Enter` — fetch and open up to `playlist_limit` current, available videos in
  playlist order
- `/` — filter saved playlists by title or channel
- `Tab` — cycle to locals

Private, deleted, and malformed entries are omitted. Each shown row is a normal
single-video URL, so playback, bookmarking, queueing, and history use the same
controls as other YouTube result lists.

Locals view: register a directory and browse its folders and media files. Each
folder is read fresh when opened and its contents are never stored, mirroring
subscriptions. Folders are shown before files; both are listed in natural order,
so `ep2` sorts before `ep10` (not after, as plain alphabetical sorting would).
Directory symlinks are omitted so browsing stays inside the registered tree.
Registrations remain saved when a directory or removable drive is disconnected;
opening it then reports that it is offline or unavailable, and it can be opened
again after the same path returns.

- `a` — register a directory: type a path (e.g. `~/Videos`), `Enter` verifies
  it and saves it under the directory's name
- `d` — remove the selected directory (`y` confirms, any other key cancels)
- `Enter` — open the directory and list its child folders and media files
- `/` — filter the list (see [Filtering](#filtering))
- `Tab` — cycle back to bookmarks

In an opened source list (a channel's videos, playlist entries, or a local
folder):

YouTube video lists (channel Videos, playlist entries, Search, and Explore
results) show **Duration** and **Views** columns alongside the title, read from
the same `yt-dlp --flat-playlist` call at no extra cost; a video that doesn't
report a field shows a blank cell. Local folders instead show Name and Type.

- `Enter` — play the selected video/file, or open the selected local folder
- `r` — reread the current local folder, preserving its filter and selected item
- `b` — bookmark the selected YouTube video (playing from a subscription or
  playlist does not auto-bookmark; local files cannot be bookmarked)
- `s` / `v` / `p` — from a channel's directly playable Videos or Streams list,
  switch to Streams, Videos, or the channel's playlist-container list. Playing a
  live entry joins at the live edge. These keys do not switch tabs inside a
  selected playlist's videos or local files.
- `e` / `n` — append the selected video to the queue, or queue it to play next
- `/` — filter the list (see [Filtering](#filtering))
- `Esc` — back to the parent local folder, or to the view the source was opened
  from when already at its root. Returning to a parent restores its cursor and
  filter exactly.

The player returns to the list or overlay it was launched from when the video
ends; queued playback advances to the next item. Network, shell, and playback
work runs in background tasks so the UI never freezes. Fetching and loading can
be canceled with `Esc`; during playback, close the external player to return
(`Q` remains available to inspect the queue).

### Explore

Press `E` from any view or video list to fetch YouTube's recommended homepage
and open it inside playmark. Explore is fetched fresh and is not persisted. It
honors your normal `yt-dlp` configuration, including cookies when configured, so
the feed can match your signed-in YouTube homepage. Without cookies, YouTube may
return anonymous recommendations or an empty feed depending on region and site
behavior.

- `j` / `k` (or arrow keys) — move the selection
- `Enter` — play the selected recommendation
- `b` — bookmark it
- `e` — append it to the queue
- `n` — queue it to play next (right after the current item)
- `Q` / `H` — open Queue or History, returning to Explore when closed
- `Esc` — return to the view, video list, or channel playlist list where Explore opened

The homepage can contain playlist, channel, and navigation cards. Explore skips
those and shows only directly playable videos and Shorts, each with **Duration**
and **Views** columns.

### Filtering

Any list can get long — a channel's uploads, a local folder, a pile of
bookmarks. Press `/` to filter it as you type:

- `/` — open the filter field over the current list (bookmarks, subscriptions,
  saved playlists, channel playlist containers, locals, a video list, or Search results)
- type to narrow the list live (case-insensitive substring over the visible
  columns — title/channel, name/URL, name/path, or video title); the highlighted
  block marks the current editing position, and `Left`/`Right`, `Home`/`End`,
  `backspace`, and `delete` can correct text at that position
- `Enter` or `Esc` — close the field, **keeping** the term (the list stays
  narrowed and the title shows e.g. `Bookmarks — "news" (3/12)`)
- `Esc` again (with the field closed) — clear the filter
- `/` again — reopen the field prefilled with the current term to edit it

`j`/`k`, `Enter`, `d`, `e`, `b`, and contextual `p` all act on the filtered
selection. Ordinary filters clear when switching views, leaving a video list,
or loading a new channel, playlist, or local folder. A local folder remembers
its filter and cursor while a child is open and when refreshed with `r`. Search
and channel playlist containers likewise preserve their parent lists independently.

### Queue

The queue is an ordered, persisted list of things to play back to back. Unlike
subscriptions, playlists, and local directories — which store a handle and fetch their
contents live — the queue stores its items outright, ordering included, so it
survives restarts. A single queue can mix YouTube videos and local files; each
item remembers which it is, so playback takes the right path for each.

From any playable list (bookmarks, a channel's videos, playlist entries, search
results, or a local folder):

- `e` — append the selected bookmark, video, or file to the queue; local folders
  themselves cannot be queued
- `n` — queue the selected item to play next, right after the current head,
  instead of at the tail (same lists as `e`)

Open the queue manager with `Q` from any list, Search or Explore results, or even
over a running player (`Q` is the only key playback accepts). In the queue
manager:

- `j` / `k` — move the selection
- `[` / `]` — move the selected item up / down in play order
- `d` — remove the selected item (`y` confirms, any other key cancels)
- `c` — clear the whole queue (`y` confirms, any other key cancels)
- `Enter` — start playing from the top (unavailable when the manager is opened
  over an active player)
- `Esc` — close the manager, back to where you opened it from
- `q` — quit playmark

Once playback starts from the queue, it auto-advances: each completed item is
dropped and the next one starts automatically — one player at a time, never two
at once. Closing mpv or VLC before the end saves progress, keeps that item, and
stops in the queue manager. If an item fails to play, the queue likewise stops
and keeps the remaining items intact. ffplay cannot distinguish a manual close
from EOF, so its clean exits retain the older remove-and-advance behavior.

### History

Every time you play something, it's recorded to a persisted watch history — the
moment playback begins, from anywhere (a bookmark, a channel's video, a search
result, a local file, or the queue). Like the queue, history stores its entries
outright, so it survives restarts. Replaying a video you've already watched just
moves it back to the top rather than adding a duplicate.

For mpv and VLC, playmark also checkpoints the position of finite, seekable media
after the first 10 seconds. Playing the same YouTube video or local path again
prompts to resume, start over, or cancel. Checkpoints are cleared at EOF or near
the final 30 seconds, and are updated periodically so they survive an application
or player interruption. Live/non-seekable media and ffplay are not checkpointed.

Open history with `H` from any list, including Search and Explore results (not
over a running player). In the History overlay:

- `j` / `k` — move the selection
- `Enter` — replay the selected entry
- `e` — append the selected entry to the queue
- `n` — queue the selected entry to play next (right after the current item)
- `d` — remove the selected entry (`y` confirms, any other key cancels)
- `c` — clear the whole history (`y` confirms, any other key cancels)
- `Esc` — close, back to where you opened it from
- `q` — quit playmark

History is unbounded — it keeps everything until you clear it.

### Playback quality

mpv and VLC request `bestvideo[height<=1080]+bestaudio/best`. mpv receives the
format through `--ytdl-format` and muxes the streams itself. For VLC, playmark
resolves separate video and audio URLs and attaches audio with `--input-slave`;
the `/best` fallback remains a single muxed stream. ffplay cannot combine split
streams, so it requests one `best[height<=1080]` muxed stream.

All players use yt-dlp's `web_safari` player client for YouTube streams, which
returns URLs that play reliably (other clients can return signed URLs that yield
`HTTP 403`). mpv passes the client through to its own yt-dlp integration; VLC and
ffplay resolve it before launching the player.

### Captions

Captions are on by default; set `subtitles = false` to turn them off. playmark
picks a track by **language first, quality second** — listing two languages ranks
them, so a machine translation into your first choice beats a human-made track in
your second:

1. an uploader-provided track in `subtitle_default` (default `en`),
2. else a translation into `subtitle_default`,
3. else an uploader-provided track in `subtitle_fallback` (optional, no default),
4. else a translation into `subtitle_fallback`,
5. else YouTube's auto-generated track in the video's spoken language.

Steps 2 and 4 need `subtitle_translate = true` (the default); set it to `false`
to drop them and get original-language captions instead.

So `subtitle_default = id` with `subtitle_fallback = en` means "Indonesian if it
exists at all, translating something if need be; otherwise English, again
translating if need be; otherwise whatever is spoken." A video with no matching
track simply plays without captions.

#### Where translations come from

YouTube will translate any caption track into ~150 languages, so a requested
language is almost always reachable. There are two sources, and playmark prefers
the better one:

- **an uploader's track** — keyed `id-en` ("Indonesian from English"). A human
  wrote the source text, so the translation has a solid input. This is the same
  thing the web player's "auto-translate" does to a manual track.
- **the auto-generated transcript** — keyed plainly (`id`). Speech recognition
  first, then translation: two lossy passes, so expect rougher results.

Given a choice, playmark translates an uploader track in a language you listed
(so you can sanity-check a line that reads strangely), then any other uploader
track, then the transcript. A Korean podcast with uploader English subtitles and
`subtitle_default = id` therefore yields `id-en` — Indonesian by way of the human
English text, not by way of Korean speech recognition.

The Now Playing panel labels which tier you got, so a bad caption is
attributable.

Captions can't ride along with the video stream, because YouTube needs a
different yt-dlp "player client" for each. The client that returns a playable
stream URL (`web_safari`) drops caption tracks; the client that exposes captions
(`default`) returns stream URLs that fail with `HTTP 403`. For the caption-capable
mpv and VLC backends, playmark makes a separate `yt-dlp` call to download the
caption track to a temporary `.vtt`, passes it through `--sub-file`, and deletes
it when playback ends. ffplay skips YouTube captions. Toggle captions in mpv with
`v`.

Local files need no download. mpv and VLC can auto-load a matching sidecar
`.srt`/`.vtt`; playmark does not attach local captions for ffplay.

### Chapters

When captions are enabled on mpv or VLC, the same metadata probe that selects a
caption track also reports the video's chapter count, which the "Now playing"
panel shows (e.g. `12 chapters`). This is informational only — playmark does no
chapter seeking. mpv navigates chapters natively (it drives yt-dlp and receives
the YouTube URL directly); VLC and ffplay play a pre-resolved stream that carries
no chapter markers. A video without chapters, or playback without a caption probe
(ffplay, or captions off), shows no chapter line.

## Development

```sh
mix test         # run the suite
mix format       # format
```

Tests use a throwaway SQLite database (`playmark_test.db`) that is created and
migrated by `test/test_helper.exs`; the app skips its startup auto-migration in
the test environment.

### Run from anywhere with Fish

Save this autoloaded function as
`~/.config/fish/functions/playmark.fish`:

```fish
function playmark --description "Run playmark from anywhere"
    set -l playmark_dir /path/to/playmark

    if not test -d "$playmark_dir"
        echo "Directory not found: $playmark_dir"
        return 1
    end

    pushd "$playmark_dir" >/dev/null; or return 1

    command mix playmark
    set -l exit_status $status

    popd >/dev/null
    return $exit_status
end
```

Change `playmark_dir` if the repository is elsewhere. Open a new Fish session or
run `source ~/.config/fish/functions/playmark.fish`, then launch the TUI from any
directory with `playmark`. The function returns to the original directory when
playmark exits.

### Recommended yt-dlp configuration

playmark honors the normal `yt-dlp` configuration; it does not pass
`--ignore-config`. Put `yt-dlp` options in its own config file, not in playmark's
`config.env`. On Linux, the user config is normally `~/.config/yt-dlp/config`.

Current YouTube extraction requires an external JavaScript runtime (Deno is
recommended) and EJS challenge-solver scripts. Official `yt-dlp` executables
already bundle the scripts, but other installations can allow `yt-dlp` to fetch
the current EJS release from GitHub when needed:

```text
# ~/.config/yt-dlp/config
--remote-components ejs:github
```

This helps solve YouTube's JavaScript and `n` challenges, which can otherwise
make formats unavailable or throttle streams. It does not install the required
JavaScript runtime. It also permits downloading executable solver code from
GitHub, so enable it only if you trust that source and your installation does
not already include `yt-dlp-ejs`. See yt-dlp's
[EJS setup guide](https://github.com/yt-dlp/yt-dlp/wiki/EJS).

If YouTube requires a signed-in session or presents a bot/CAPTCHA block, you can
also opt in to loading cookies directly from Firefox:

```text
# ~/.config/yt-dlp/config
--cookies-from-browser firefox
```

This can make Explore match the signed-in homepage and allow account-gated
content. It also makes every `yt-dlp` process read the Firefox cookie store and
use that session for its requests, which can add startup latency and exposes the
account to the risks of automated access. yt-dlp's
[YouTube cookie guidance](https://github.com/yt-dlp/yt-dlp/wiki/Extractors#exporting-youtube-cookies)
warns that using an account can lead to temporary or permanent bans, so use
cookies only when needed, preferably with a separate account/profile. If Firefox
has multiple profiles, select one with `--cookies-from-browser firefox:PROFILE`.

These settings apply to channel and playlist loading, Search, Explore, caption
downloads, and online stream resolution (including mpv's `yt-dlp` integration).
They do not affect local playback or bookmark metadata fetched through oEmbed.
