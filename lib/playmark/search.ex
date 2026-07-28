defmodule Playmark.Search do
  @moduledoc """
  Searches YouTube with `yt-dlp`, without an API key.

  `yt-dlp` accepts a `ytsearchN:QUERY` pseudo-URL that returns YouTube's search
  results as a playlist. Combined with `--flat-playlist`, it emits the same
  `id`/`title` line format `Playmark.Channel` reads for a channel listing. The TUI
  keeps these rows in an isolated Search overlay where they can be played,
  bookmarked, queued, and filtered without replacing the underlying page.

  Results follow YouTube's relevance ranking (not date-sorted). For a query like
  "today's news" that surfaces fresh videos in practice, since YouTube already
  ranks recent news highly, but it is not a strict date filter.

  This mirrors `Playmark.Channel`: shell out to `yt-dlp`, parse its line-oriented
  output, return a tagged tuple. Titles are enriched through the same oEmbed path
  (`Playmark.Channel.enrich_titles/1`) so they match what bookmarking would store.
  """

  alias Playmark.Channel

  # Same ASCII Unit Separator (0x1F) `Playmark.Channel` uses, so the shared
  # `parse_videos/1` splits id from title reliably.
  @sep "\x1F"

  # Default result count when the user hasn't set :search_limit (Playmark.Config).
  @default_limit 20

  # Bounds each yt-dlp socket read/connect so a black-holed network can't hang a
  # search forever (matching Playmark.Channel). The TUI terminates its tracked
  # Search task on cancellation; this remains the final network bound.
  @default_socket_timeout 30

  @doc """
  Searches YouTube for `query`, returning up to `limit` results by relevance.

  `limit` defaults to the user's `:search_limit` (or #{@default_limit}).

  Returns `{:ok, [%{id: String.t(), title: String.t(), url: String.t()}]}` or
  `{:error, reason}`. Each map also carries `:live`, `:duration`, and `:views`
  (see `Playmark.Channel.parse_videos/1`).
  """
  def search(query, limit \\ limit()) when is_binary(query) and is_integer(limit) do
    query = String.trim(query)

    if query == "" do
      {:error, "search query is empty"}
    else
      case System.cmd("yt-dlp", build_args(query, limit), stderr_to_stdout: true) do
        {output, 0} -> {:ok, output |> Channel.parse_videos() |> Channel.enrich_titles()}
        {output, code} -> {:error, "yt-dlp failed (exit #{code}): #{String.trim(output)}"}
      end
    end
  end

  @doc """
  Builds the `yt-dlp` arg list for a search.

  The query is a single element of the arg list — passed straight to `yt-dlp`,
  never through a shell — so no quoting or escaping is needed and it can't inject
  extra arguments.
  """
  def build_args(query, limit) when is_binary(query) and is_integer(limit) do
    [
      "--socket-timeout",
      socket_timeout(),
      "--flat-playlist",
      "--print",
      "%(id)s#{@sep}%(title)s#{@sep}%(live_status)s#{@sep}%(duration)s#{@sep}%(view_count)s",
      "ytsearch#{limit}:#{query}"
    ]
  end

  # User-overridable result count (see Playmark.Config), default @default_limit.
  defp limit, do: Application.get_env(:playmark, :search_limit, @default_limit)

  # yt-dlp socket timeout as a string arg (shared :socket_timeout key, default
  # @default_socket_timeout — see Playmark.Config and Playmark.Channel).
  defp socket_timeout,
    do: to_string(Application.get_env(:playmark, :socket_timeout, @default_socket_timeout))
end
