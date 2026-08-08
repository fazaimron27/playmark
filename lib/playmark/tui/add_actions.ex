defmodule Playmark.TUI.AddActions do
  @moduledoc """
  The two ways a row enters the database: typed into the add field, or
  bookmarked from a video list.

  Both spawn a task rather than blocking the runtime, and both are best-effort
  in the same way — the task *always* sends a result, even on an unexpected
  raise, so a failed add reports an error instead of stranding the UI in
  `:fetching`.

  These are one concept despite the two entry points: `start_add/2`'s
  `:bookmarks` clause and `bookmark_video/2` make the same
  `Playmark.Bookmarks.add_bookmark/1` call, reached from the input field and
  from a video row respectively. The difference is what the UI does while it
  waits — an add takes over the screen with `:fetching` mode, a bookmark leaves
  the list usable and only sets a status.

  Which context an add targets is decided by the active view, matched in the
  clause heads. That is the one piece of core state this module reads, and it is
  read-only.
  """

  alias Playmark.Bookmarks
  alias Playmark.TUI.Impl

  # --- bookmarking a video --------------------------------------------------

  @doc false
  # `parent` is captured here, in the runtime process — this is reached
  # synchronously from handle_event/2 via the videos, Explore, and Search key
  # handlers, so the result lands back in the runtime regardless of which list
  # the row came from.
  def bookmark_video(video, state) do
    parent = self()

    Task.start(fn ->
      result =
        try do
          Bookmarks.add_bookmark(video.url)
        rescue
          error -> {:error, Exception.message(error)}
        end

      send(parent, {:bookmark_video_result, result})
    end)

    %{state | status: {:info, "Bookmarking #{video.title}…"}}
  end

  # --- adding a bookmark, subscription, playlist, or local -----------------

  @doc false
  # Add a bookmark, subscription, playlist, or local depending on the active view,
  # off the runtime process. The task always sends a result, even on an
  # unexpected raise, so we never get stuck in :fetching.
  def start_add(url, %{view: :bookmarks} = state) do
    parent = self()

    Task.start(fn ->
      result =
        try do
          Bookmarks.add_bookmark(url)
        rescue
          error -> {:error, Exception.message(error)}
        end

      send(parent, {:add_result, result})
    end)

    %{state | mode: :fetching, status: {:info, "Fetching metadata… (Esc to cancel)"}}
  end

  def start_add(url, %{view: :subscriptions} = state) do
    parent = self()
    subscriptions = Impl.subscriptions()

    Task.start(fn ->
      result =
        try do
          subscriptions.add_subscription(url)
        rescue
          error -> {:error, Exception.message(error)}
        end

      send(parent, {:add_result, result, :subscription})
    end)

    %{state | mode: :fetching, status: {:info, "Adding channel… (Esc to cancel)"}}
  end

  def start_add(url, %{view: :playlists} = state) do
    parent = self()
    playlists = Impl.playlists()

    Task.start(fn ->
      result =
        try do
          playlists.add_playlist(url)
        rescue
          error -> {:error, Exception.message(error)}
        end

      send(parent, {:add_result, result, :playlist})
    end)

    %{state | mode: :fetching, status: {:info, "Adding playlist… (Esc to cancel)"}}
  end

  def start_add(path, %{view: :locals} = state) do
    parent = self()
    locals = Impl.locals()

    Task.start(fn ->
      result =
        try do
          locals.add_local(path)
        rescue
          error -> {:error, Exception.message(error)}
        end

      send(parent, {:add_result, result, :local})
    end)

    %{state | mode: :fetching, status: {:info, "Registering directory… (Esc to cancel)"}}
  end
end
