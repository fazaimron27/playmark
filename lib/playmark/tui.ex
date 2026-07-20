defmodule Playmark.TUI do
  @moduledoc """
  The playmark terminal UI.

  A LiveView-style ExRatatui app with three top-level views — Bookmarks,
  Subscriptions, and Search — cycled with `Tab`, and a mode state machine layered
  on top:

    * `:list`     — browse the current view's list. `j`/`k` move, `a` adds
                    (`/` in Search, which opens a query prompt), `d` deletes,
                    `Tab` cycles view, `q` quits. `Enter` plays a bookmark or
                    opens a subscription's latest videos (the Search view holds
                    no list here — results arrive in `:videos`).
    * `:input`    — type into a `TextInput`. `Enter` submits, `Esc` cancels.
                    Adds a bookmark, adds a subscription, or runs a YouTube
                    search depending on the active view.
    * `:fetching` — a background task is adding a bookmark/subscription.
    * `:loading`  — a background task is listing a channel's videos or running a
                    search.
    * `:videos`   — browse a subscription's latest videos or a search's results.
                    `Enter` plays, `b` bookmarks the selected video, `Esc` goes
                    back to the view it was opened from.
    * `:playing`  — an external player owns the screen; keys are ignored until
                    it closes.

  Subscriptions store only the channel URL and name; the video list is fetched
  live (via `Playmark.Channel`) each time a subscription is opened, so it is
  always current and nothing stale is persisted.

  Every operation that shells out or hits the network (adding, listing videos,
  playback) runs in a spawned task and reports back via `handle_info/2`, so the
  runtime never blocks. Long-running states accept `Esc` to bail out; a result
  arriving after a cancel is dropped via a mode guard.

  This module is the `ExRatatui.App` shell: it owns the runtime callbacks and
  routes work to two collaborators — `Playmark.TUI.Actions` for state
  transitions (key handling, navigation, task spawning) and `Playmark.TUI.View`
  for rendering.
  """

  use ExRatatui.App

  require Logger

  alias ExRatatui.Event
  alias Playmark.{Bookmarks, Playlists, Queue, Subscriptions}
  alias Playmark.TUI.{Actions, View}

  @impl true
  def mount(_opts) do
    # The TextInput's editor state lives in a NIF resource: create it once here
    # and thread it through state. Rebuilding it in render/2 would wipe the
    # cursor and typed text every frame.
    input = ExRatatui.text_input_new()

    {:ok,
     %{
       view: :bookmarks,
       mode: :list,
       bookmarks: Bookmarks.list_bookmarks(),
       subscriptions: Subscriptions.list_subscriptions(),
       playlists: Playlists.list_playlists(),
       queue: Queue.list_items(),
       videos: [],
       channel_name: nil,
       selected: 0,
       # The selection index inside the queue-manage modal, kept separate from
       # `selected` so opening/closing the modal doesn't disturb the base view's
       # cursor.
       queue_selected: 0,
       # The mode to restore when the queue-manage modal closes (the modal can be
       # opened from :list, :videos, or :playing).
       queue_return: :list,
       input: input,
       status: nil,
       playing: nil
     }}
  end

  # --- event routing -------------------------------------------------------

  # Only act on key presses; ignore key releases and auto-repeat.
  @impl true
  def handle_event(%Event.Key{kind: kind}, state) when kind != "press" do
    {:noreply, state}
  end

  # "Q" opens the queue-manage modal from anywhere it's reachable — a browsable
  # list (:list/:videos) or over the running player (:playing). It's the only key
  # :playing accepts; see the catch-all guard below. Placed before the
  # mode-specific routes so it wins in those modes too.
  def handle_event(%Event.Key{code: "Q"}, %{mode: mode} = state)
      when mode in [:list, :videos, :playing] do
    {:noreply, Actions.open_queue(state)}
  end

  def handle_event(%Event.Key{} = key, %{mode: :queue_manage} = state) do
    Actions.handle_queue_key(key.code, state)
  end

  def handle_event(%Event.Key{} = key, %{mode: :list} = state) do
    Actions.handle_list_key(key.code, state)
  end

  def handle_event(%Event.Key{} = key, %{mode: :videos} = state) do
    Actions.handle_videos_key(key.code, state)
  end

  def handle_event(%Event.Key{} = key, %{mode: :input} = state) do
    Actions.handle_input_key(key, state)
  end

  # Esc bails out of a background add/list that's taking too long. The task keeps
  # running but its result is dropped on arrival (see the mode guards in
  # handle_info), so a hung request can't strand the UI.
  def handle_event(%Event.Key{code: "esc"}, %{mode: mode} = state)
      when mode in [:fetching, :loading] do
    {:noreply, %{state | mode: Actions.back_mode(state), status: {:info, "Canceled"}}}
  end

  def handle_event(%Event.Key{}, %{mode: mode} = state)
      when mode in [:fetching, :loading, :playing] do
    {:noreply, state}
  end

  # Bracketed paste arrives as one event, not a stream of key presses, so it
  # bypasses handle_input_key entirely. Insert it into the field when adding.
  def handle_event(%Event.Paste{content: content}, %{mode: :input} = state) do
    ExRatatui.text_input_insert_str(state.input, content)
    {:noreply, state}
  end

  def handle_event(_event, state) do
    {:noreply, state}
  end

  # --- add results (bookmark or subscription) ------------------------------

  # Only acted on while still fetching: if the user canceled with Esc, mode is
  # already back to :list and we drop the late result.
  @impl true
  def handle_info({:add_result, {:ok, bookmark}}, %{mode: :fetching} = state) do
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

  def handle_info({:add_result, {:ok, subscription}, :subscription}, %{mode: :fetching} = state) do
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

  def handle_info({:add_result, {:ok, playlist}, :playlist}, %{mode: :fetching} = state) do
    {:noreply,
     %{
       state
       | view: :local,
         mode: :list,
         playlists: Playlists.list_playlists(),
         selected: 0,
         status: {:info, "Added: #{playlist.name}"}
     }}
  end

  def handle_info({:add_result, {:error, reason}, _target}, %{mode: :fetching} = state) do
    {:noreply, %{state | mode: :input, status: {:error, add_error(reason)}}}
  end

  def handle_info({:add_result, {:error, reason}}, %{mode: :fetching} = state) do
    {:noreply, %{state | mode: :input, status: {:error, add_error(reason)}}}
  end

  # Results that arrive after the add was canceled (mode no longer :fetching).
  def handle_info({:add_result, _result}, state), do: {:noreply, state}
  def handle_info({:add_result, _result, _target}, state), do: {:noreply, state}

  # --- channel video listing ----------------------------------------------

  def handle_info({:videos_result, {:ok, videos}, name}, %{mode: :loading} = state) do
    status =
      if videos == [],
        do: {:info, "No videos found for #{name}"},
        else: {:info, "#{length(videos)} videos from #{name}"}

    {:noreply,
     %{state | mode: :videos, videos: videos, channel_name: name, selected: 0, status: status}}
  end

  def handle_info({:videos_result, {:error, reason}, _name}, %{mode: :loading} = state) do
    {:noreply, %{state | mode: :list, status: {:error, "Could not load videos: #{reason}"}}}
  end

  # Late video-list result after cancel.
  def handle_info({:videos_result, _result, _name}, state), do: {:noreply, state}

  # --- local file listing --------------------------------------------------
  # A local playlist's files land in the same :videos mode as a channel listing;
  # the directory name stands in for the channel name as the header label.

  def handle_info({:files_result, {:ok, files}, name}, %{mode: :loading} = state) do
    status =
      if files == [],
        do: {:info, "No media files in #{name}"},
        else: {:info, "#{length(files)} files in #{name}"}

    {:noreply,
     %{state | mode: :videos, videos: files, channel_name: name, selected: 0, status: status}}
  end

  def handle_info({:files_result, {:error, reason}, _name}, %{mode: :loading} = state) do
    {:noreply, %{state | mode: :list, status: {:error, "Could not read directory: #{reason}"}}}
  end

  # Late file-list result after cancel.
  def handle_info({:files_result, _result, _name}, state), do: {:noreply, state}

  # --- search results ------------------------------------------------------
  # A search lands in the same :videos mode as a channel listing; the query
  # stands in for the channel name as the header label.

  def handle_info({:search_result, {:ok, videos}, query}, %{mode: :loading} = state) do
    status =
      if videos == [],
        do: {:info, "No results for #{query}"},
        else: {:info, "#{length(videos)} results for #{query}"}

    {:noreply,
     %{state | mode: :videos, videos: videos, channel_name: query, selected: 0, status: status}}
  end

  def handle_info({:search_result, {:error, reason}, _query}, %{mode: :loading} = state) do
    {:noreply, %{state | mode: :list, status: {:error, "Search failed: #{reason}"}}}
  end

  # Late search result after cancel (mode no longer :loading).
  def handle_info({:search_result, _result, _query}, state), do: {:noreply, state}

  # --- bookmarking a video from the subscription view ----------------------
  # Stays in :videos mode; only the status line reflects progress/outcome.

  def handle_info({:bookmark_video_result, {:ok, bookmark}}, state) do
    {:noreply,
     %{
       state
       | bookmarks: Bookmarks.list_bookmarks(),
         status: {:info, "Bookmarked: #{bookmark.title}"}
     }}
  end

  def handle_info({:bookmark_video_result, {:error, reason}}, state) do
    {:noreply, %{state | status: {:error, "Bookmark failed: #{add_error(reason)}"}}}
  end

  # --- playback ------------------------------------------------------------

  # The caption chain resolved to a concrete track (or none): record it under the
  # captions submap so the view can show which language/tier was actually chosen,
  # not just the configured preference. Guarded on :playing like the stage clause.
  def handle_info(
        {:play_progress, {:caption, result}},
        %{mode: :playing, playing: %{captions: captions} = playing} = state
      )
      when is_map(captions) do
    {:noreply, %{state | playing: %{playing | captions: %{captions | result: result}}}}
  end

  # Stream resolution produced a concrete shape (split video+audio, or a single
  # muxed stream): record it under the stream submap so the view can firm up the
  # "Resolving stream" line. Guarded on :playing like the caption clause.
  def handle_info(
        {:play_progress, {:stream, shape}},
        %{mode: :playing, playing: %{stream: stream} = playing} = state
      )
      when is_map(stream) do
    {:noreply, %{state | playing: %{playing | stream: %{stream | result: shape}}}}
  end

  # A backend advancing through its stages. Fold the stage into the playing map
  # so the view can mark that step done and light up the next one. Guarded on
  # :playing mode, so a stage arriving after playback ended (or was left) is
  # dropped like the other stale async results.
  def handle_info({:play_progress, stage}, %{mode: :playing, playing: playing} = state)
      when is_map(playing) and is_atom(stage) do
    {:noreply, %{state | playing: %{playing | stage: stage}}}
  end

  def handle_info({:play_progress, _stage}, state), do: {:noreply, state}

  # A queued item finished cleanly: drop it from the queue and, if anything's
  # left, play the next head — staying in :playing. This is where auto-advance
  # lives, and why the queue never runs two players at once: the next only starts
  # now, after the previous one's player closed and sent this message.
  def handle_info({:play_result, :ok}, %{playing: %{origin: :queue, queue_id: id}} = state) do
    Queue.remove_by_id(id)
    queue = Queue.list_items()
    state = %{state | queue: queue}

    case Queue.head() do
      nil ->
        {:noreply, %{state | mode: :list, playing: nil, status: {:info, "Queue finished"}}}

      item ->
        playable = %{title: item.title, url: item.url, local: item.local}
        {:noreply, Actions.start_play(playable, :queue, state, item.id)}
    end
  end

  def handle_info({:play_result, :ok}, state) do
    {:noreply, %{state | mode: play_return_mode(state), playing: nil, status: nil}}
  end

  # A queued item failed: stop the queue and surface the error, leaving the failed
  # item in place so it's visible where playback stopped (stop-and-report, not
  # skip). Drop to the queue-manage modal so the user sees the remaining items.
  def handle_info({:play_result, {:error, reason}}, %{playing: %{origin: :queue}} = state) do
    Logger.error("Playback failed: #{reason}")

    {:noreply,
     %{
       state
       | mode: :queue_manage,
         queue_return: :list,
         queue: Queue.list_items(),
         queue_selected: 0,
         playing: nil,
         status: {:error, "Playback failed: #{reason}"}
     }}
  end

  def handle_info({:play_result, {:error, reason}}, state) do
    Logger.error("Playback failed: #{reason}")

    {:noreply,
     %{
       state
       | mode: play_return_mode(state),
         playing: nil,
         status: {:error, "Playback failed: #{reason}"}
     }}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- rendering -----------------------------------------------------------

  @impl true
  def render(state, frame), do: View.render(state, frame)

  # --- handle_info helpers -------------------------------------------------

  # After playback, return to whichever list we launched from: the video list if
  # we were browsing a subscription, otherwise the main list.
  defp play_return_mode(%{videos: videos}) when videos != [], do: :videos
  defp play_return_mode(_state), do: :list

  defp add_error(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp add_error(reason), do: to_string(reason)
end
