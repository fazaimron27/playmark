defmodule Playmark.TUI.Filter do
  @moduledoc """
  Pure list filtering for `Playmark.TUI`, shared by `Playmark.TUI.Actions`
  (navigation) and `Playmark.TUI.View` (rendering) so the two can never diverge
  on what's visible.

  The filter is a case-insensitive substring match over a row's visible columns.
  Which list and which fields to match depend on the current view/mode, mirroring
  `Actions.current_list/1` exactly — `base_list/1` and `fields/1` are the single
  place that mapping lives, and `visible/1` composes them with the active term.

  The lists are small in-memory lists of maps already in TUI state (dozens of
  rows), so this stays plain Elixir — no shelling out, no async. An empty term is
  the identity filter (the whole list). Rows may be Ecto structs (bookmarks,
  subscriptions, playlists, locals) or plain video maps; both answer `Map.get/2`
  for the matched fields, so `matches?/3` treats them uniformly.
  """

  @doc """
  True when `row` matches `term` in any of `fields`. An empty term matches
  everything. Non-binary / missing field values never match.
  """
  def matches?(_row, _fields, ""), do: true

  def matches?(row, fields, term) do
    term = String.downcase(term)

    Enum.any?(fields, fn field ->
      case Map.get(row, field) do
        value when is_binary(value) -> String.contains?(String.downcase(value), term)
        _ -> false
      end
    end)
  end

  @doc """
  Keeps the rows of `rows` matching `term` in any of `fields`. An empty term
  returns the list unchanged. (Named `narrow` rather than `apply` to avoid the
  clash with `Kernel.apply/3`.)
  """
  def narrow(rows, _fields, ""), do: rows
  def narrow(rows, fields, term), do: Enum.filter(rows, &matches?(&1, fields, term))

  @doc """
  The unfiltered list the selection points into for the given state. Mirrors
  `Playmark.TUI.Actions.current_list/1`: the video list while browsing videos,
  otherwise the active view's list. Search and channel-playlist rows are handled
  separately because their parent browse state must remain intact.

  While the filter field is open the runtime mode is `:filter`, so we resolve
  through `effective_mode/1` to the base mode the field was opened over
  (`filter_return`) — the list being narrowed doesn't change just because the
  field is focused.
  """
  def base_list(state), do: base_list(effective_mode(state), state)

  defp base_list(:videos, %{videos: videos}), do: videos
  defp base_list(_mode, %{view: :bookmarks, bookmarks: bookmarks}), do: bookmarks
  defp base_list(_mode, %{view: :subscriptions, subscriptions: subscriptions}), do: subscriptions
  defp base_list(_mode, %{view: :playlists, playlists: playlists}), do: playlists
  defp base_list(_mode, %{view: :locals, locals: locals}), do: locals

  @doc """
  The fields a row matches against, per view/mode. The video list matches on
  title only; the persisted lists match on their two visible columns.
  """
  def fields(state), do: fields(effective_mode(state), state)

  defp fields(:videos, _state), do: [:title]
  defp fields(_mode, %{view: :bookmarks}), do: [:title, :channel]
  defp fields(_mode, %{view: :subscriptions}), do: [:name, :url]
  defp fields(_mode, %{view: :playlists}), do: [:title, :channel]
  defp fields(_mode, %{view: :locals}), do: [:name, :path]
  defp fields(_mode, _state), do: []

  # The mode the filter applies over: the base mode while the field is open
  # (`:filter` → its `filter_return`), otherwise the current mode.
  defp effective_mode(%{mode: :filter, filter_return: return}), do: return
  defp effective_mode(%{mode: mode}), do: mode

  @doc """
  The list actually shown/navigated for `state`: its base list narrowed by the
  active `state.filter` term. A state without a `:filter` key (e.g. a partial
  test fixture) is treated as no filter.
  """
  def visible(state), do: narrow(base_list(state), fields(state), term(state))

  @doc "Returns the independently filtered rows in the Search overlay."
  def visible_search(state) do
    narrow(Map.get(state, :search_videos, []), [:title], Map.get(state, :search_filter, ""))
  end

  @doc "Returns the independently filtered playlist containers for an open channel."
  def visible_channel_playlists(state) do
    narrow(
      Map.get(state, :channel_playlists, []),
      [:title],
      Map.get(state, :channel_playlist_filter, "")
    )
  end

  defp term(state), do: Map.get(state, :filter) || ""
end
