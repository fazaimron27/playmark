defmodule Playmark.TUI do
  @moduledoc """
  The playmark terminal UI.

  A LiveView-style ExRatatui app with three top-level views — Bookmarks,
  Subscriptions, and Search — cycled with `Tab`, and a mode state machine layered
  on top:

    * `:list`     — browse the current view's list. `j`/`k` move, `a` adds
                    (`/` in Search, which opens a query prompt), `d` deletes
                    (via a `:confirm` prompt), `Tab` cycles view, `q` quits.
                    `Enter` plays a bookmark or opens a subscription's latest
                    videos (the Search view holds no list here — results arrive
                    in `:videos`).
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
    * `:confirm`  — a destructive action (list `d` delete, queue/history `d`
                    single-item remove, or queue/history `c` clear) is staged
                    behind a `y`/`n` prompt; `y` performs it, any other key
                    cancels. The underlying list/queue/history stays on screen
                    with the prompt shown in the footer.
    * `:history`  — browse watch history (an overlay opened with `H` from
                    `:list`/`:videos`, not over the player). `Enter` replays,
                    `d` removes one entry, `c` clears all (via `:confirm`),
                    `Esc` closes back to where it was opened.

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
  alias Playmark.{Bookmarks, History, Playlists, Queue, Subscriptions}
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
       # Watch history (newest first), and — like the queue — a modal selection
       # index and the mode to restore when the history modal closes. The history
       # modal is reachable from :list/:videos only (not over the running player).
       history: History.list_items(),
       history_selected: 0,
       history_return: :list,
       # A pending destructive action awaiting y/n confirmation (%{action, prompt}),
       # nil outside :confirm mode; confirm_return is the mode to restore after.
       confirm: nil,
       confirm_return: :list,
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

  # "H" opens the watch-history modal from a browsable list (:list/:videos). Unlike
  # the queue's "Q", it is NOT accepted over the running player — the :playing
  # catch-all below ignores it. Placed before the mode-specific routes so it wins
  # in :list/:videos too.
  def handle_event(%Event.Key{code: "H"}, %{mode: mode} = state)
      when mode in [:list, :videos] do
    {:noreply, Actions.open_history(state)}
  end

  def handle_event(%Event.Key{} = key, %{mode: :history} = state) do
    Actions.handle_history_key(key.code, state)
  end

  # A destructive action (list delete, queue/history single-item remove, or
  # queue/history clear) staged behind a yes/no prompt. "y" performs it; any other
  # key cancels (see Actions.handle_confirm_key/2).
  def handle_event(%Event.Key{} = key, %{mode: :confirm} = state) do
    Actions.handle_confirm_key(key.code, state)
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

  def handle_info({:add_result, {:error, reason}, target}, %{mode: :fetching} = state) do
    {:noreply, %{state | mode: :input, status: {:error, add_error(reason, target)}}}
  end

  def handle_info({:add_result, {:error, reason}}, %{mode: :fetching} = state) do
    {:noreply, %{state | mode: :input, status: {:error, add_error(reason, :bookmark)}}}
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
    {:noreply, %{state | status: {:error, "Bookmark failed: #{add_error(reason, :bookmark)}"}}}
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

  # The status-clear timer fired (see subscriptions/1). Clear the footer status,
  # but only if it still matches the status the timer was armed for — a newer
  # status set in the meantime must not be wiped. (The runtime also drops a stale
  # tick by token when the status changed, so this is belt-and-suspenders.)
  def handle_info({:clear_status, status}, %{status: status} = state) do
    {:noreply, %{state | status: nil}}
  end

  def handle_info({:clear_status, _status}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # --- subscriptions -------------------------------------------------------

  # A one-shot timer to clear a transient footer status after a few seconds, so a
  # stale "Added: …" / error doesn't linger indefinitely. The runtime reconciles
  # this after every transition (see ExRatatui.App), so we declare it purely as a
  # function of state: a set status arms the timer, a nil status returns none and
  # disarms it. The message carries the current status, which does double duty —
  # it lets handle_info avoid clobbering a newer status, and (because the runtime
  # diffs subscriptions by their fields) it forces a fresh timer whenever the
  # status changes, so each new message gets its own full window rather than
  # inheriting the previous one's already-fired timer.
  @status_clear_ms 5_000

  @impl true
  def subscriptions(%{status: nil}), do: []

  def subscriptions(%{status: status}) do
    [ExRatatui.Subscription.once(:status_clear, @status_clear_ms, {:clear_status, status})]
  end

  # --- rendering -----------------------------------------------------------

  @impl true
  def render(state, frame), do: View.render(state, frame)

  # --- handle_info helpers -------------------------------------------------

  # After playback, return to whichever list we launched from: the video list if
  # we were browsing a subscription, otherwise the main list.
  defp play_return_mode(%{videos: videos}) when videos != [], do: :videos
  defp play_return_mode(_state), do: :list

  # A duplicate (the unique index on :url / :path) is the common, expected add
  # failure — the raw "url has already been taken" reads poorly, so we map it to a
  # per-target message. `target` is :bookmark / :subscription / :playlist. Any
  # other changeset error keeps the generic field-by-field text; a plain reason
  # (e.g. a yt-dlp/oEmbed string) passes through unchanged.
  defp add_error(%Ecto.Changeset{} = changeset, target) do
    if duplicate?(changeset), do: duplicate_message(target), else: changeset_errors(changeset)
  end

  defp add_error(reason, _target), do: to_string(reason)

  # True when the changeset failed only because the URL/path is already taken.
  defp duplicate?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} -> opts[:constraint] == :unique end)
  end

  defp duplicate_message(:subscription), do: "Already subscribed to this channel"
  defp duplicate_message(:playlist), do: "Directory already registered"
  defp duplicate_message(_bookmark), do: "Already bookmarked"

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end
end
