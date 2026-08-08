defmodule Playmark.TUI.Nav do
  @moduledoc """
  Pure cursor and row helpers shared by the `Playmark.TUI` action modules.

  Every browse list in the TUI — the base lists, videos, channel playlists,
  Search, Explore, the queue, and history — moves its cursor the same way: a
  signed delta for `j`/`k` and PageUp/PageDown, a `:top`/`:bottom` jump for
  `g`/`G`/Home/End, and a clamp at both ends. Each list owns a separate cursor
  field so the movers themselves can't be shared, but the arithmetic under them
  can — that is what lives here.

  Nothing here touches TUI state, spawns a task, or does IO. These take plain
  integers, lists, and row maps and return the same, so they're testable without
  a runtime.
  """

  @page_step 10

  @doc """
  How many rows PageUp/PageDown move. There is no terminal-height value in TUI
  state (lists render through an auto-scrolling Table), so paging uses a fixed
  step rather than a real screenful; `clamp/3` bounds the ends.
  """
  def page_step, do: @page_step

  @doc """
  The absolute index for a jump-to-edge (`:top`/`:bottom`), or `nil` for an empty
  list. Shared by every mover so `g`/`G`/Home/End behave uniformly.
  """
  def jump_index([], _target), do: nil
  def jump_index(_list, :top), do: 0
  def jump_index(list, :bottom), do: length(list) - 1

  @doc "Bounds `n` to the inclusive `lo`..`hi` range."
  def clamp(n, lo, _hi) when n < lo, do: lo
  def clamp(n, _lo, hi) when n > hi, do: hi
  def clamp(n, _lo, _hi), do: n

  @doc """
  Bounds `index` to a selectable position in `list`. An empty list clamps to 0
  rather than -1, so a cursor left over an emptied list still points at a
  renderable slot.
  """
  def clamp_index(index, list), do: clamp(index, 0, max(length(list) - 1, 0))

  @doc """
  The channel name for an item, fed to the player as artist metadata. Its key
  differs by source: a bookmark stores `:channel`, an enriched channel/search
  video carries `:author`, and a local file has neither. `nil` when absent — the
  player then sets no artist flag.
  """
  def item_author(item) do
    Map.get(item, :author) || Map.get(item, :channel)
  end

  @doc """
  The source-agnostic `%{title, url, local, author}` map that the play and
  enqueue paths take, built from a YouTube video row. `local: false` — local
  files reach those paths through their own entry rows, never through this.
  """
  def playable_video(video) do
    %{title: video.title, url: video.url, local: false, author: item_author(video)}
  end
end
