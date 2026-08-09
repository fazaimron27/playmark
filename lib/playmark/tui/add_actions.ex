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

  alias Playmark.{Bookmarks, Locals, Playlists, Subscriptions}
  alias Playmark.TUI.{Impl, Status}

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

  @doc false
  # The other half of `bookmark_video/2`, called from Playmark.TUI.handle_info/2.
  # No mode guard and no request ref: the originating list stayed usable, so
  # there is no state a late result could corrupt — it just refreshes the
  # bookmark list and sets a status.
  def handle_bookmark_result({:bookmark_video_result, {:ok, bookmark}}, state) do
    {:noreply,
     %{
       state
       | bookmarks: Bookmarks.list_bookmarks(),
         status: {:info, "Bookmarked: #{bookmark.title}"}
     }}
  end

  def handle_bookmark_result({:bookmark_video_result, {:error, reason}}, state) do
    {:noreply,
     %{state | status: {:error, "Bookmark failed: #{Status.add_error(reason, :bookmark)}"}}}
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

  @doc false
  # The other half of `start_add/2`, called from Playmark.TUI.handle_info/2.
  #
  # Only acted on while still fetching: if the user canceled with Esc, mode is
  # already back to :list and we drop the late result.
  #
  # Each success clause switches to the view it added to and re-reads that
  # context, which means writing `view`, `mode`, and `selected` — and `selected`
  # is a browse-core key the overlay modules otherwise leave alone. It is a
  # deliberate exception, recorded in CLAUDE.md: this is a terminal "the add
  # finished, show me the row" commit, not ongoing collaboration with the browse
  # cursor. Note that the invariant's published grep matches dot reads, not the
  # `%{state | …}` writes these clauses use, so it will not flag them.
  def handle_result({:add_result, {:ok, bookmark}}, %{mode: :fetching} = state) do
    {:noreply,
     %{
       state
       | view: :bookmarks,
         mode: :list,
         bookmarks: Bookmarks.list_bookmarks(),
         selected: 0,
         status: {:info, "Added: #{bookmark.title}"}
     }}
  end

  def handle_result({:add_result, {:ok, subscription}, :subscription}, %{mode: :fetching} = state) do
    {:noreply,
     %{
       state
       | view: :subscriptions,
         mode: :list,
         subscriptions: Subscriptions.list_subscriptions(),
         selected: 0,
         status: {:info, "Subscribed: #{subscription.name}"}
     }}
  end

  def handle_result({:add_result, {:ok, local}, :local}, %{mode: :fetching} = state) do
    {:noreply,
     %{
       state
       | view: :locals,
         mode: :list,
         locals: Locals.list_locals(),
         selected: 0,
         status: {:info, "Added: #{local.name}"}
     }}
  end

  def handle_result({:add_result, {:ok, playlist}, :playlist}, %{mode: :fetching} = state) do
    {:noreply,
     %{
       state
       | view: :playlists,
         mode: :list,
         playlists: Playlists.list_playlists(),
         selected: 0,
         status: {:info, "Added: #{playlist.title}"}
     }}
  end

  def handle_result({:add_result, {:error, reason}, target}, %{mode: :fetching} = state) do
    {:noreply, %{state | mode: :input, status: {:error, Status.add_error(reason, target)}}}
  end

  def handle_result({:add_result, {:error, reason}}, %{mode: :fetching} = state) do
    {:noreply, %{state | mode: :input, status: {:error, Status.add_error(reason, :bookmark)}}}
  end

  # Results that arrive after the add was canceled (mode no longer :fetching).
  def handle_result({:add_result, _result}, state), do: {:noreply, state}
  def handle_result({:add_result, _result, _target}, state), do: {:noreply, state}
end
