# playmark

A terminal UI for playing video without leaving your terminal — bookmark
YouTube videos, subscribe to channels, search YouTube, and browse local
directories, then play any of it in your media player. YouTube metadata is
fetched without any API key (via the public oEmbed endpoint), streams are
resolved with `yt-dlp`, and playback hands off to `mpv` or `vlc`.

## Requirements

- Elixir 1.18+ / Erlang OTP 26+
- [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) on your `PATH`
- A media player on your `PATH`: [`mpv`](https://mpv.io) (default) or
  [`vlc`](https://www.videolan.org/vlc/)

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
player = mpv              # mpv (default) or vlc
max_height = 1080         # cap playback resolution (video height in pixels)
subtitles = true          # show captions (default true)
subtitle_default = en     # first-choice caption language (default en)
subtitle_fallback = id    # second-choice language (optional, no default)
search_limit = 20         # results per YouTube search
channel_limit = 30        # videos fetched when opening a channel
oembed_timeout_ms = 4000  # per-title metadata lookup timeout
oembed_concurrency = 10   # parallel metadata lookups
```

Settings are read at startup, so restart playmark after editing the file. An
unknown key or an invalid value is skipped (with a warning at launch) and the
default stands, so a typo won't stop the app from starting.

### Choosing a player

Playback defaults to mpv; set `player = vlc` to use VLC. mpv drives `yt-dlp`
itself and handles HLS/muxing natively. VLC can't fetch YouTube pages, so playmark
resolves the stream URLs with `yt-dlp -g` first and hands VLC the raw stream(s).

## Usage

Launch the TUI:

```sh
mix playmark
```

The TUI has four views — **Bookmarks**, **Subscriptions**, **Search**, and
**Local** — cycled with `Tab`.

Bookmarks view:

- `j` / `k` (or arrow keys) — move the selection
- `a` — add a bookmark: type/paste a YouTube URL, `Enter` fetches its title and
  channel and saves it, `Esc` cancels
- `d` — delete the selected bookmark
- `Enter` — play the selected video in the configured player
- `Tab` — cycle to subscriptions
- `q` — quit

Subscriptions view: subscribe to a channel and browse its latest videos live —
the video list is fetched fresh each time (via `yt-dlp --flat-playlist`) and
never stored, so it's always current.

- `a` — add a subscription: paste a channel URL (e.g.
  `https://www.youtube.com/@handle`), `Enter` resolves the channel name
  and saves it
- `d` — unsubscribe from the selected channel
- `Enter` — open the channel and list its latest videos
- `Tab` — cycle to search

Search view: query YouTube directly, no API key.

- `/` — enter a query, `Enter` runs the search, `Esc` cancels
- results arrive in the same video list as an opened subscription
- `Tab` — cycle to local

Results follow YouTube's relevance ranking (not strictly date-sorted).

Local view: register a directory and play the media files inside it — the file
list is read fresh each time (top level only) and never stored, mirroring
subscriptions.

- `a` — register a directory: type a path (e.g. `~/Videos`), `Enter` verifies
  it and saves it under the directory's name
- `d` — remove the selected directory
- `Enter` — open the directory and list its media files
- `Tab` — cycle back to bookmarks

In a video list (a channel's videos, search results, or a directory's files):

- `Enter` — play the selected video or file
- `b` — bookmark the selected video (subscriptions, search, and bookmarks stay
  separate; playing from a subscription or search does not auto-bookmark; local
  files can't be bookmarked)
- `Esc` — back to the view it was opened from

The player closes back to the list when the video ends. Every fetch, channel
listing, and playback runs in the background, so the UI never freezes; long
operations show a status and accept `Esc` to cancel.

### Queue

The queue is an ordered, persisted list of things to play back to back. Unlike
subscriptions and local directories — which store only a handle and fetch their
contents live — the queue stores its items outright, ordering included, so it
survives restarts. A single queue can mix YouTube videos and local files; each
item remembers which it is, so playback takes the right path for each.

From any list (bookmarks, a channel's videos, search results, or a directory's
files):

- `e` — append the selected bookmark, video, or file to the queue

Open the queue manager with `Q` from a list, a video list, or even over a
running player (`Q` is the only key playback accepts). In the queue manager:

- `j` / `k` — move the selection
- `[` / `]` — move the selected item up / down in play order
- `d` — remove the selected item
- `c` — clear the whole queue
- `Enter` — start playing from the top
- `Esc` — close the manager, back to where you opened it from

Once playback starts from the queue, it auto-advances: each item plays to the
end, is dropped from the queue, and the next one starts automatically — one
player at a time, never two at once. If an item fails to play, the queue stops,
shows the error, and drops you back into the queue manager with the remaining
items intact so you can remove the offender and continue.

### Playback quality

Both players request `bestvideo[height<=1080]+bestaudio/best`. With mpv, the
format string is passed via `--ytdl-format` and mpv muxes the video and audio
streams itself. With VLC, YouTube's separate video-only and audio-only streams
come back as two URLs: the video plays with the audio attached as an
`--input-slave`; a single pre-muxed stream (the `/best` fallback) is played
directly.

Both players resolve streams through yt-dlp's `web_safari` player client, which
returns an HLS URL that plays reliably (other clients can return signed URLs
that yield `HTTP 403`).

### Captions

Captions are on by default; set `subtitles = false` to turn them off. playmark
picks a track by a three-step preference chain:

1. an uploader-provided track in `subtitle_default` (default `en`),
2. else an uploader-provided track in `subtitle_fallback` (optional, no default),
3. else YouTube's auto-generated track in the video's spoken language.

So `subtitle_default = id` with `subtitle_fallback = en` means "prefer the
uploader's Indonesian captions, then their English ones, then auto-generated
captions in whatever language is spoken." A video with no matching track simply
plays without captions.

Captions can't ride along with the video stream, because YouTube needs a
different yt-dlp "player client" for each. The client that returns a playable
stream URL (`web_safari`) drops caption tracks; the client that exposes captions
(`default`) returns stream URLs that fail with `HTTP 403`. So for both players
playmark makes a separate `yt-dlp` call to download the caption track to a
temporary `.vtt` file, hands it to the player via `--sub-file`, and deletes it
when playback ends. Toggle captions in mpv with `v`.

Local files need no download: both players auto-load a sidecar `.srt`/`.vtt`
sitting next to the media file with a matching name.

## Development

```sh
mix test         # run the suite
mix format       # format
```

Tests use a throwaway SQLite database (`playmark_test.db`) that is created and
migrated by `test/test_helper.exs`; the app skips its startup auto-migration in
the test environment.
