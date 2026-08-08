defmodule Playmark.TUI.Impl do
  @moduledoc """
  The swappable implementations behind the outside-world calls `Playmark.TUI`
  makes.

  Each function names the module to call for one boundary — playback, the
  yt-dlp/network sources, the Ecto contexts — by reading an application env key
  that falls back to the real module. Tests install a stub with
  `Application.put_env(:playmark, :channel_impl, StubChannel)` and clean up in
  `on_exit`, so the suite never spawns a player, shells out to yt-dlp, or
  touches the network.

  The key is read from the application env on every call, so it makes no
  difference which module does the reading — these live here rather than in
  `Playmark.TUI.Actions` only so the action modules can share one list.

  ## Not every call to these modules belongs here

  `Playmark.Playback` is called two ways, and conflating them breaks the suite
  in a way that presents as a hang rather than a failure. Its *IO* — `play/4`,
  `play_local/4`, `player/0`, `resume_supported?/0` — goes through `playback/0`
  below. Its *config reads* — `max_height/0`, `subtitles?/0`,
  `subtitle_default/0`, `subtitle_fallback/0` — are called on the real module
  directly, because a test stub implements only the IO half. Route a config read
  through this seam and it raises `UndefinedFunctionError` inside a spawned
  task; no result message is ever sent, and the test blocks on `assert_receive`
  until it times out.
  """

  alias Playmark.Source.{Channel, Explore, LocalFiles, Search, YouTubePlaylist}
  alias Playmark.{History, Locals, Playback, Playlists, Subscriptions}

  @doc "Playback IO only — see the moduledoc on config reads."
  def playback, do: Application.get_env(:playmark, :playback_impl, Playback)

  def channel, do: Application.get_env(:playmark, :channel_impl, Channel)
  def subscriptions, do: Application.get_env(:playmark, :subscriptions_impl, Subscriptions)
  def search, do: Application.get_env(:playmark, :search_impl, Search)
  def explore, do: Application.get_env(:playmark, :explore_impl, Explore)
  def playlists, do: Application.get_env(:playmark, :playlists_impl, Playlists)
  def locals, do: Application.get_env(:playmark, :locals_impl, Locals)
  def local_files, do: Application.get_env(:playmark, :local_files_impl, LocalFiles)

  def youtube_playlist,
    do: Application.get_env(:playmark, :youtube_playlist_impl, YouTubePlaylist)

  def history, do: Application.get_env(:playmark, :history_impl, History)
end
