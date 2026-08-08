defmodule Playmark.TUI.View do
  @moduledoc """
  Pure rendering for `Playmark.TUI`: turns UI state into a list of
  `{widget, rect}` tuples. No side effects and no state transitions live here —
  everything is a function of the state map handed in by the runtime.

  The layout gains a dedicated input row while adding (`:input`/`:fetching`) or
  filtering (`:filter`/`:search_filter`), and while entering a Search query
  (`:search_input`). Other modes use the header/body/footer split.
  """

  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, Paragraph, Table, TextInput}

  alias Playmark.TUI.Filter

  @input_cursor_style %Style{modifiers: [:reversed]}

  def render(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    footer_height = footer_height(state)

    if state.mode in [
         :input,
         :fetching,
         :filter,
         :channel_playlists_filter,
         :search_input,
         :search_filter
       ] do
      [header_area, body_area, input_area, footer_area] =
        Layout.split(area, :vertical, [
          {:length, 3},
          {:min, 0},
          {:length, 3},
          {:length, footer_height}
        ])

      [
        {header(state), header_area},
        {body(state), body_area},
        {input_widget(state), input_area},
        {footer(state), footer_area}
      ]
    else
      [header_area, body_area, footer_area] =
        Layout.split(area, :vertical, [{:length, 3}, {:min, 0}, {:length, footer_height}])

      [
        {header(state), header_area},
        {body(state), body_area},
        {footer(state), footer_area}
      ]
    end
  end

  defp header(state) do
    %Paragraph{
      text: "playmark — #{section(state)}",
      style: %Style{fg: :magenta, modifiers: [:bold]},
      alignment: :center,
      block: %Block{borders: [:all], border_type: :rounded, border_style: %Style{fg: :magenta}}
    }
  end

  defp section(%{mode: :confirm, confirm_return: :queue_manage}), do: "Queue"
  defp section(%{mode: :confirm, confirm_return: :history}), do: "History"

  # The queue-manage modal names itself, whatever base view it was opened over.
  defp section(%{mode: :queue_manage}), do: "Queue"

  # The history modal likewise names itself, over whatever base view.
  defp section(%{mode: :history}), do: "History"

  # The help overlay names itself, over whatever base view.
  defp section(%{mode: :help}), do: "Help"

  defp section(%{mode: mode}) when mode in [:explore_loading, :explore], do: "Explore"

  defp section(%{mode: mode})
       when mode in [:search_input, :search_loading, :search_results, :search_filter],
       do: "Search"

  defp section(%{mode: :playing, playing: %{return_mode: :search_results}}), do: "Search"
  defp section(%{mode: :playing, playing: %{return_mode: :explore}}), do: "Explore"

  defp section(%{mode: :resume, resume: %{display_mode: display_mode}} = state),
    do: section(%{state | mode: display_mode})

  defp section(%{view: :locals, local_path: path} = state) when is_binary(path),
    do: local_breadcrumb(state)

  defp section(%{mode: mode, channel_playlist_channel_name: name})
       when mode in [:channel_playlists_loading, :channel_playlists, :channel_playlists_filter],
       do: name

  # While browsing a channel's videos — or playing one launched from that list —
  # retain the channel name as source context (see showing_videos?/1).
  defp section(%{channel_name: name} = state) when name != nil do
    if showing_videos?(state), do: name, else: view_section(state)
  end

  defp section(state), do: view_section(state)

  defp view_section(%{view: :bookmarks}), do: "Bookmarks"
  defp view_section(%{view: :subscriptions}), do: "Subscriptions"
  defp view_section(%{view: :playlists}), do: "Playlists"
  defp view_section(%{view: :locals}), do: "Locals"

  # The body renders the active overlay, playback progress panel, opened source
  # list, or top-level view in that order.
  defp body(state) do
    cond do
      # A resume decision is an overlay over the exact page that requested the
      # play. Render that page while the footer carries the three-way prompt.
      state.mode == :resume ->
        body(%{state | mode: state.resume.display_mode})

      # A queue-clear confirmation keeps the queue on screen (the prompt shows in
      # the footer) so the user sees what they're about to wipe. A list-delete
      # confirmation needs no special branch — it falls through to the view-based
      # clauses below, which don't gate on mode, so the list stays visible.
      state.mode == :confirm and confirm_over_queue?(state) ->
        queue_body(state)

      state.mode == :confirm and confirm_over_history?(state) ->
        history_body(state)

      state.mode == :queue_manage ->
        queue_body(state)

      state.mode == :history ->
        history_body(state)

      state.mode == :help ->
        help_body()

      state.mode == :explore_loading ->
        explore_loading_body()

      state.mode == :explore ->
        explore_body(state)

      state.mode == :search_input ->
        search_input_body()

      state.mode == :search_loading ->
        search_loading_body(state)

      state.mode in [:search_results, :search_filter] ->
        search_results_body(state)

      state.mode == :channel_playlists_loading ->
        channel_playlists_loading_body(state)

      state.mode in [:channel_playlists, :channel_playlists_filter] ->
        channel_playlists_body(state)

      state.mode == :playing ->
        now_playing(state)

      showing_videos?(state) ->
        state = video_browse_state(state)
        {title, empty_text} = videos_labels(state)
        videos = Filter.visible(state)
        title = filter_title(state, title, videos)
        empty_text = filter_empty(state, empty_text)

        # Local folders and files share the video-list mode but expose their type;
        # streams instead badge each row's live status (LIVE / ENDED / SOON).
        cond do
          state.view == :locals ->
            table_or_empty(
              Enum.map(videos, &[&1.title, local_entry_type(&1)]),
              ["Name", "Type"],
              [{:percentage, 80}, {:percentage, 20}],
              state.selected,
              title,
              empty_text
            )

          Map.get(state, :video_tab) == :streams ->
            table_or_empty(
              Enum.map(videos, &[&1.title, live_badge(&1.live)]),
              ["Title", "Status"],
              [{:percentage, 85}, {:percentage, 15}],
              state.selected,
              title,
              empty_text
            )

          true ->
            table_or_empty(
              Enum.map(videos, &video_row(&1)),
              ["Title", "Duration", "Views"],
              [{:percentage, 64}, {:percentage, 16}, {:percentage, 20}],
              state.selected,
              title,
              empty_text
            )
        end

      base_view(state) == :bookmarks ->
        bookmarks = Filter.visible(state)

        table_or_empty(
          Enum.map(bookmarks, &[&1.title, &1.channel]),
          ["Title", "Channel"],
          [{:percentage, 65}, {:percentage, 35}],
          state.selected,
          filter_title(state, " Bookmarks ", bookmarks),
          filter_empty(
            state,
            "No bookmarks yet.\n\nPress \"a\" to add one, or Tab for Subscriptions."
          )
        )

      base_view(state) == :subscriptions ->
        subscriptions = Filter.visible(state)

        table_or_empty(
          Enum.map(subscriptions, &[&1.name, &1.url]),
          ["Channel", "URL"],
          [{:percentage, 40}, {:percentage, 60}],
          state.selected,
          filter_title(state, " Subscriptions ", subscriptions),
          filter_empty(
            state,
            "No subscriptions yet.\n\nPress \"a\" to add a channel, or Tab for Playlists."
          )
        )

      base_view(state) == :playlists ->
        playlists = Filter.visible(state)

        table_or_empty(
          Enum.map(playlists, &[&1.title, &1.channel || ""]),
          ["Playlist", "Channel"],
          [{:percentage, 40}, {:percentage, 60}],
          state.selected,
          filter_title(state, " Playlists ", playlists),
          filter_empty(
            state,
            "No playlists yet.\n\nPress \"a\" to add a YouTube playlist, or Tab for Locals."
          )
        )

      base_view(state) == :locals ->
        locals = Filter.visible(state)

        table_or_empty(
          Enum.map(locals, &[&1.name, &1.path]),
          ["Name", "Directory"],
          [{:percentage, 40}, {:percentage, 60}],
          state.selected,
          filter_title(state, " Locals ", locals),
          filter_empty(
            state,
            "No local directories yet.\n\nPress \"a\" to register one, or Tab for Bookmarks."
          )
        )

      true ->
        table_or_empty(
          [],
          ["Title"],
          [{:percentage, 100}],
          state.selected,
          " Playmark ",
          "No items."
        )
    end
  end

  # The queue-manage modal's body: the queued items with a Source column
  # (local file vs YouTube), so the local? fork the play path takes is visible.
  defp queue_body(state) do
    table_or_empty(
      Enum.map(state.queue, &[&1.title, queue_source(&1)]),
      ["Title", "Source"],
      [{:percentage, 80}, {:percentage, 20}],
      state.queue_selected,
      " Queue ",
      "Queue is empty.\n\nPress \"e\" on a bookmark, video, or file to add it here."
    )
  end

  defp queue_source(%{local: true}), do: "Local"
  defp queue_source(_item), do: "YouTube"

  defp channel_playlists_loading_body(state) do
    %Paragraph{
      text: "Loading playlists from #{state.channel_playlist_channel_name}…",
      alignment: :center,
      style: %Style{fg: :cyan},
      block: %Block{title: " Playlists ", borders: [:all], border_type: :rounded}
    }
  end

  defp channel_playlists_body(state) do
    playlists = Filter.visible_channel_playlists(state)

    title =
      case state.channel_playlist_filter do
        "" ->
          " Playlists "

        term ->
          ~s|Playlists — "#{term}" (#{length(playlists)}/#{length(state.channel_playlists)})|
      end

    empty_text =
      if state.channel_playlist_filter == "",
        do: "No playlists found for this channel.",
        else: ~s|No matches for "#{state.channel_playlist_filter}".|

    table_or_empty(
      Enum.map(playlists, &[&1.title]),
      ["Playlist"],
      [{:percentage, 100}],
      state.channel_playlist_selected,
      title,
      empty_text
    )
  end

  # The history modal's body: recent plays newest-first, with a "When" column
  # (a relative age of played_at) so the recency the list is ordered by is visible.
  defp history_body(state) do
    table_or_empty(
      Enum.map(state.history, &[&1.title, history_when(&1)]),
      ["Title", "When"],
      [{:percentage, 80}, {:percentage, 20}],
      state.history_selected,
      " History ",
      "No history yet.\n\nPlay something to see it here."
    )
  end

  # A static, hand-authored keybinding reference grouped by context. It's the one
  # place the full key set is spelled out — the footers only surface a mode's most
  # relevant keys — so it's kept in sync with the handlers in Playmark.TUI.Actions.
  defp help_body do
    %Paragraph{
      text: help_text(),
      alignment: :left,
      style: %Style{fg: :white},
      block: %Block{title: " Help ", borders: [:all], border_type: :rounded}
    }
  end

  defp help_text do
    """
    Global (from any browse list)
      S: search   E: explore   Q: queue   H: history
      ?: this help   q: quit

    Lists (bookmarks, subscriptions, playlists, locals, videos)
      j/k or ↑/↓: move        g/Home: top     G/End: bottom
      PageUp/PageDown: page   /: filter       Enter: play/open
      a: add   d: delete   Tab: next view
      b: bookmark (video lists)
      e: queue (tail)   n: play next (after head)
      r: refresh (local folder)

    Channel
      v: videos   s: streams   p: playlists
      Enter on a playlist: open   p on a playlist: save

    Queue (Q)
      j/k: move   [ / ]: reorder   d: remove   c: clear
      Enter: play from top   Esc: close

    History (H)
      j/k: move   Enter: replay   e: queue   n: play next
      d: remove   c: clear   Esc: close

    Filter (/)
      type to narrow   Enter/Esc: keep   Esc again: clear

    Esc / ?: close this help
    """
  end

  defp explore_loading_body do
    %Paragraph{
      text: "Loading YouTube recommendations…",
      alignment: :center,
      style: %Style{fg: :cyan},
      block: %Block{title: " Explore ", borders: [:all], border_type: :rounded}
    }
  end

  defp explore_body(state) do
    table_or_empty(
      Enum.map(state.explore_videos, &video_row(&1)),
      ["Title", "Duration", "Views"],
      [{:percentage, 64}, {:percentage, 16}, {:percentage, 20}],
      state.explore_selected,
      " Explore ",
      "No recommendations found.\n\nPress Esc to return, then E to try again."
    )
  end

  defp search_input_body do
    %Paragraph{
      text: "Search YouTube.\n\nType a query below and press Enter.",
      alignment: :center,
      style: %Style{fg: :yellow},
      block: %Block{title: " Search ", borders: [:all], border_type: :rounded}
    }
  end

  defp search_loading_body(state) do
    %Paragraph{
      text: "Searching for #{state.search_query}…",
      alignment: :center,
      style: %Style{fg: :cyan},
      block: %Block{title: " Search ", borders: [:all], border_type: :rounded}
    }
  end

  defp search_results_body(state) do
    videos = Filter.visible_search(state)
    title = search_filter_title(state, videos)

    empty_text =
      if state.search_filter == "",
        do: "No results.",
        else: ~s|No matches for "#{state.search_filter}".|

    table_or_empty(
      Enum.map(videos, &video_row(&1)),
      ["Title", "Duration", "Views"],
      [{:percentage, 64}, {:percentage, 16}, {:percentage, 20}],
      state.search_selected,
      title,
      empty_text
    )
  end

  defp search_filter_title(%{search_filter: "", search_query: query}, _videos),
    do: " Search results — #{query} "

  defp search_filter_title(state, videos) do
    ~s|Search results — "#{state.search_filter}" (#{length(videos)}/#{length(state.search_videos)})|
  end

  # A compact relative age for a history item's played_at (e.g. "just now",
  # "5m ago", "3h ago", "2d ago"). Uses whole units; falls back to a blank for a
  # missing/odd timestamp so the column never crashes the renderer.
  defp history_when(%{played_at: %DateTime{} = played_at}) do
    secs = DateTime.diff(DateTime.utc_now(), played_at, :second)

    cond do
      secs < 60 -> "just now"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end

  defp history_when(_item), do: ""

  # A compact runtime for a video row: "M:SS" under an hour, "H:MM:SS" beyond.
  # A nil/absent duration (a source that omits it, or a local file) renders blank
  # so the column never crashes the renderer.
  defp format_duration(secs) when is_integer(secs) and secs >= 0 do
    hours = div(secs, 3600)
    minutes = div(rem(secs, 3600), 60)
    seconds = rem(secs, 60)

    if hours > 0 do
      "#{hours}:#{pad2(minutes)}:#{pad2(seconds)}"
    else
      "#{minutes}:#{pad2(seconds)}"
    end
  end

  defp format_duration(_other), do: ""

  # A compact view count: raw under 1K, else one decimal with a K/M/B suffix and
  # a trailing ".0" trimmed (1_240_000 -> "1.2M", 12_000 -> "12K"). A nil/absent
  # count renders blank.
  defp format_views(n) when is_integer(n) and n >= 0 do
    cond do
      n < 1_000 -> Integer.to_string(n)
      n < 1_000_000 -> compact(n, 1_000, "K")
      n < 1_000_000_000 -> compact(n, 1_000_000, "M")
      true -> compact(n, 1_000_000_000, "B")
    end
  end

  defp format_views(_other), do: ""

  defp compact(n, unit, suffix) do
    scaled = Float.round(n / unit, 1)
    whole = trunc(scaled)

    text = if scaled == whole * 1.0, do: Integer.to_string(whole), else: Float.to_string(scaled)
    text <> suffix
  end

  defp pad2(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

  # A Title / Duration / Views row for the playable video lists (channel uploads,
  # playlist entries, Search, Explore). Reads the metadata fields defensively so a
  # row shape without them (an older cached map) renders blank cells, not a crash.
  defp video_row(video) do
    [
      video.title,
      format_duration(Map.get(video, :duration)),
      format_views(Map.get(video, :views))
    ]
  end

  # True when a confirmation is staged over the queue modal (clearing the queue),
  # so the body keeps showing the queue behind the prompt rather than the base
  # view. A list-delete confirmation (confirm_return: :list) falls through to the
  # normal view branches instead.
  defp confirm_over_queue?(%{mode: :confirm, confirm_return: :queue_manage}), do: true
  defp confirm_over_queue?(_state), do: false

  # True when a confirmation is staged over the history modal (clearing history), so
  # the body keeps showing the history behind the prompt rather than the base view.
  defp confirm_over_history?(%{mode: :confirm, confirm_return: :history}), do: true
  defp confirm_over_history?(_state), do: false

  # True while browsing a source list or playing an item launched from it. During
  # playback this retains the source label in the header; the body itself is the
  # Now Playing panel. While filtering, `filter_return` identifies the source list.
  defp showing_videos?(%{mode: :videos}), do: true
  defp showing_videos?(%{mode: :filter, filter_return: :videos}), do: true

  defp showing_videos?(%{
         mode: :loading,
         view: :locals,
         loading_return: :videos,
         local_pending: %{refresh: true}
       }),
       do: true

  defp showing_videos?(%{mode: :playing, videos: videos}), do: videos != []
  defp showing_videos?(_state), do: false

  defp video_browse_state(%{mode: :loading} = state), do: %{state | mode: :videos}
  defp video_browse_state(state), do: state

  # The base view a body branch keys off. Unchanged by the filter field being
  # open — only the runtime mode is :filter then, not the view.
  defp base_view(%{view: view}), do: view

  # When a filter term is active, append it and the shown/total count to the
  # table title (e.g. `Bookmarks — "news" (3/12)`); otherwise leave the title as
  # is. `shown` is the filtered list; the total comes from the unfiltered base.
  defp filter_title(state, title, shown) do
    case Map.get(state, :filter) || "" do
      "" ->
        title

      term ->
        total = length(Filter.base_list(state))
        ~s|#{String.trim(title)} — "#{term}" (#{length(shown)}/#{total})|
    end
  end

  # The empty-state text: with an active filter that matched nothing, say so
  # rather than showing the "add your first item" hint; otherwise the given text.
  defp filter_empty(state, empty_text) do
    case Map.get(state, :filter) || "" do
      "" -> empty_text
      term -> ~s|No matches for "#{term}".|
    end
  end

  # The "Now playing" panel shown in :playing mode: the video title on top, then
  # the ordered steps for this play (seeded in Playmark.TUI.Actions) as a checklist
  # that advances as the backend reports each stage. During :resolving/:captions
  # the external player hasn't taken the screen yet, so this panel is what the user
  # sees; once the external player launches it covers the terminal until it closes.
  defp now_playing(%{playing: %{steps: _steps, stage: _stage} = playing}) do
    %Paragraph{
      text: now_playing_text(playing),
      alignment: :center,
      block: %Block{
        title: " Now playing ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :cyan}
      }
    }
  end

  # Defensive: :playing with no seeded map (e.g. a test that forces the mode)
  # shouldn't crash the renderer.
  defp now_playing(_state) do
    %Paragraph{
      text: "Playing…",
      alignment: :center,
      style: %Style{fg: :cyan, modifiers: [:bold]},
      block: %Block{borders: [:all], border_type: :rounded, border_style: %Style{fg: :cyan}}
    }
  end

  defp now_playing_text(%{steps: steps, stage: stage} = playing) do
    checklist =
      steps
      |> Enum.map(&step_line(&1, stage, steps, playing))
      |> Enum.join("\n")

    resume =
      case Map.get(playing, :resume_position_ms) do
        position when is_integer(position) and position > 0 ->
          "\n\nresuming at #{playback_time(position)}"

        _other ->
          ""
      end

    "#{playing.title}\n\nin #{playing.player}#{resume}#{chapters_detail(playing)}\n\n#{checklist}"
  end

  # The chapter count from the caption probe, shown only once known and non-zero
  # (mpv/VLC with captions on). nil (no probe / not yet reported) or 0 (no
  # chapters) renders nothing. Informational: mpv navigates chapters natively;
  # VLC/ffplay play a pre-resolved stream without chapter markers.
  defp chapters_detail(%{chapters: count}) when is_integer(count) and count > 0 do
    "\n\n#{count} #{if count == 1, do: "chapter", else: "chapters"}"
  end

  defp chapters_detail(_playing), do: ""

  # Each step is done, current, or pending relative to the reported stage. Steps
  # earlier in the ordered list than the current stage are done; the current stage
  # is in progress; the rest are pending. The initial :starting stage (before any
  # report) leaves every step pending. The status shows as a padded text prefix
  # (rather than an icon) so it reads clearly on any terminal font.
  defp step_line(step, stage, steps, playing) do
    "#{step_status(step, stage, steps)} #{step_label(step, playing)}"
  end

  defp step_status(step, stage, steps) do
    status =
      cond do
        step == stage -> "in progress"
        done?(step, stage, steps) -> "done"
        true -> "waiting"
      end

    # Left-align in a fixed-width bracket so the labels line up in a column.
    "[#{String.pad_trailing(status, 11)}]"
  end

  defp done?(step, stage, steps) do
    step_index = Enum.find_index(steps, &(&1 == step))
    stage_index = Enum.find_index(steps, &(&1 == stage))
    stage_index != nil and step_index < stage_index
  end

  defp step_label(:playing, _playing), do: "Playing"

  # The stream step (VLC and ffplay) carries detail beyond a bare label: the quality
  # cap it's resolving under (the configured :max_height), and — once yt-dlp has
  # returned URLs — the resolved shape: a split video+audio pair (recombined for
  # the player) or a single muxed stream. `stream.result` is nil until the backend reports.
  defp step_label(:resolving, %{stream: stream}),
    do: "Resolving stream — #{stream_detail(stream)}"

  defp step_label(:resolving, _playing), do: "Resolving stream"

  # The caption step carries detail beyond a bare label: which language it's after
  # (the configured default, and the fallback if set), and — once the preference
  # chain has resolved against the video — the concrete track it found: the actual
  # language and whether it's an uploader-provided or auto-generated track, or that
  # none matched. `captions.result` is nil until the backend reports the outcome.
  defp step_label(:captions, %{captions: captions}), do: "Captions — #{caption_detail(captions)}"
  defp step_label(:captions, _playing), do: "Captions"

  # Before resolution: state the quality ceiling being requested.
  defp stream_detail(%{result: nil, max_height: max_height}), do: "up to #{max_height}p"

  # After resolution: the concrete rendition yt-dlp handed back.
  defp stream_detail(%{result: :split, max_height: max_height}),
    do: "#{max_height}p cap, video+audio"

  defp stream_detail(%{result: :muxed, max_height: max_height}),
    do: "#{max_height}p cap, muxed"

  # No stream map (older/forced state) — fall back to the bare word.
  defp stream_detail(_stream), do: "resolving"

  # Before resolution: state the target language and any fallback.
  defp caption_detail(%{result: nil, default: default, fallback: fallback}) do
    "seeking #{lang(default)}#{fallback_suffix(fallback)}"
  end

  # After resolution: the concrete track that won the preference chain. A
  # translated track is called out separately from a native auto one — it's a
  # machine translation of a speech-recognition transcript, a rougher tier the
  # user should be able to attribute a bad caption to.
  defp caption_detail(%{result: {:manual, key}}), do: "#{lang(key)}, uploader-provided"
  defp caption_detail(%{result: {:translated, key}}), do: "#{lang(key)}, auto-translated"
  defp caption_detail(%{result: {:auto, key}}), do: "#{lang(key)}, auto-generated"
  defp caption_detail(%{result: :none}), do: "none available"

  # No captions map (older/forced state) — fall back to the bare word.
  defp caption_detail(_captions), do: "fetching"

  defp fallback_suffix(nil), do: ""
  defp fallback_suffix(""), do: ""
  defp fallback_suffix(fallback), do: ", fallback #{lang(fallback)}"

  defp lang(nil), do: "?"
  defp lang(""), do: "?"
  defp lang(code), do: code

  # The ordinary video list is shared by subscriptions, playlists, and locals.
  defp videos_labels(%{videos_return: :channel_playlists}),
    do: {" Playlist videos ", "No available videos."}

  defp videos_labels(%{view: :playlists}), do: {" Playlist videos ", "No available videos."}

  defp videos_labels(%{view: :locals} = state),
    do: {" #{local_breadcrumb(state)} ", "No media files or folders in this directory."}

  defp videos_labels(%{video_tab: :streams}), do: {" Streams ", "No streams in this channel."}
  defp videos_labels(_state), do: {" Videos ", "No videos in this channel."}

  # The Status-column label for a stream row's live state. `:none` (a regular
  # upload that happens to sit on the Streams tab) shows blank rather than a badge.
  defp live_badge(:live), do: "LIVE"
  defp live_badge(:ended), do: "ENDED"
  defp live_badge(:upcoming), do: "SOON"
  defp live_badge(_none), do: ""

  defp local_entry_type(%{kind: :directory}), do: "Folder"
  defp local_entry_type(_file), do: "File"

  defp local_breadcrumb(state) do
    root = Map.get(state, :local_root)
    path = Map.get(state, :local_path)
    root_name = Map.get(state, :local_root_name) || (is_binary(root) && Path.basename(root))

    cond do
      not is_binary(path) ->
        root_name || "Files"

      not is_binary(root) or path == root ->
        root_name || Path.basename(path)

      true ->
        Path.join(root_name || Path.basename(root), Path.relative_to(path, root))
    end
  end

  defp table_or_empty([], _header, _widths, _selected, title, empty_text) do
    %Paragraph{
      text: empty_text,
      style: %Style{fg: :yellow},
      alignment: :center,
      block: %Block{title: title, borders: [:all], border_type: :rounded}
    }
  end

  defp table_or_empty(rows, header, widths, selected, title, _empty_text) do
    %Table{
      rows: rows,
      header: header,
      widths: widths,
      selected: clamp(selected, 0, length(rows) - 1),
      header_style: %Style{fg: :cyan, modifiers: [:bold]},
      highlight_style: %Style{fg: :black, bg: :cyan, modifiers: [:bold]},
      highlight_symbol: "▶ ",
      block: %Block{title: title, borders: [:all], border_type: :rounded}
    }
  end

  defp input_widget(%{mode: :input, view: view, input: input}) do
    {title, placeholder} = input_labels(view)

    %TextInput{
      state: input,
      cursor_style: @input_cursor_style,
      placeholder: placeholder,
      placeholder_style: %Style{fg: :dark_gray},
      block: %Block{
        title: title,
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :green}
      }
    }
  end

  defp input_widget(%{mode: :fetching} = state) do
    %Paragraph{
      text: fetching_text(state),
      style: %Style{fg: :cyan, modifiers: [:bold]},
      alignment: :center,
      block: %Block{borders: [:all], border_type: :rounded, border_style: %Style{fg: :cyan}}
    }
  end

  defp input_widget(%{mode: :search_input, input: input}) do
    %TextInput{
      state: input,
      cursor_style: @input_cursor_style,
      placeholder: "today's news",
      placeholder_style: %Style{fg: :dark_gray},
      block: %Block{
        title: " Search YouTube — type a query ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :green}
      }
    }
  end

  defp input_widget(%{mode: :filter, input: input}) do
    %TextInput{
      state: input,
      cursor_style: @input_cursor_style,
      block: %Block{
        title: " Filter ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :green}
      }
    }
  end

  defp input_widget(%{mode: :search_filter, input: input}) do
    %TextInput{
      state: input,
      cursor_style: @input_cursor_style,
      block: %Block{
        title: " Filter search results ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :green}
      }
    }
  end

  defp input_widget(%{mode: :channel_playlists_filter, input: input}) do
    %TextInput{
      state: input,
      cursor_style: @input_cursor_style,
      block: %Block{
        title: " Filter channel playlists ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :green}
      }
    }
  end

  defp input_labels(:subscriptions),
    do: {" Add subscription — paste a channel URL ", "https://www.youtube.com/@handle/videos"}

  defp input_labels(:playlists),
    do:
      {" Add playlist — paste a YouTube playlist URL ", "https://www.youtube.com/playlist?list=…"}

  defp input_labels(:locals),
    do: {" Register directory — type a path ", "~/Videos"}

  defp input_labels(_bookmarks),
    do: {" Add bookmark — paste a YouTube URL ", "https://www.youtube.com/watch?v=…"}

  defp fetching_text(%{view: :subscriptions}), do: "Adding channel… (Esc to cancel)"
  defp fetching_text(%{view: :playlists}), do: "Adding playlist… (Esc to cancel)"
  defp fetching_text(%{view: :locals}), do: "Registering directory… (Esc to cancel)"
  defp fetching_text(_bookmarks), do: "Fetching metadata… (Esc to cancel)"

  defp footer(state) do
    {text, fg} = footer_content(state)

    %Paragraph{
      text: text,
      style: %Style{fg: fg},
      alignment: :center,
      block: %Block{borders: [:all], border_type: :rounded, border_style: %Style{fg: :blue}}
    }
  end

  # A bordered paragraph needs two extra rows around its content. Browse modes
  # use two deliberate lines so every global shortcut remains visible at 80
  # columns; compact status and input footers keep their original height.
  defp footer_height(state) do
    {text, _fg} = footer_content(state)
    text |> String.split("\n") |> length() |> Kernel.+(2)
  end

  # A status message (success or error) always wins over the mode hints. An error
  # can carry raw multi-line stderr, which would overflow the compact footer, so
  # it is collapsed to a single readable line. Info messages are app-authored and
  # short, so they are left as-is.
  defp footer_content(%{status: {:error, msg}}), do: {short_error(msg), :red}
  defp footer_content(%{status: {:info, msg}}), do: {msg, :green}

  # A staged confirmation shows its prompt and the y/n choice, in a warning color
  # so a destructive action reads as one. Placed above the mode hints; the
  # confirm state clears `status` on entry so nothing masks it.
  defp footer_content(%{mode: :confirm, confirm: %{prompt: prompt}}),
    do: {"#{prompt}  (y: yes | any other key: cancel)", :yellow}

  defp footer_content(%{
         mode: :resume,
         resume: %{playable: playable, position_ms: position_ms}
       }) do
    {"Resume \"#{playable.title}\" from #{playback_time(position_ms)}?  " <>
       "(y: resume | n: start over | Esc: cancel)", :yellow}
  end

  defp footer_content(%{mode: :input}), do: {"Enter: add | Esc: cancel", :white}
  defp footer_content(%{mode: :search_input}), do: {"Enter: search | Esc: back", :white}
  defp footer_content(%{mode: :fetching}), do: {"Working… (Esc to cancel)", :cyan}
  defp footer_content(%{mode: :loading}), do: {"Loading… (Esc to cancel)", :cyan}
  defp footer_content(%{mode: :search_loading}), do: {"Searching… (Esc to cancel)", :cyan}
  defp footer_content(%{mode: :explore_loading}), do: {"Loading… (Esc to cancel)", :cyan}

  defp footer_content(%{mode: :channel_playlists_loading}),
    do: {"Loading… (Esc to cancel)", :cyan}

  # The filter field's own hints: typing narrows the list live, Enter/Esc close
  # the field keeping the term (cleared later with Esc in the base mode).
  defp footer_content(%{mode: :filter}),
    do: {"type to filter | Enter/Esc: keep | backspace: edit", :white}

  defp footer_content(%{mode: :search_filter}),
    do: {"type to filter | Enter/Esc: keep | backspace: edit", :white}

  defp footer_content(%{mode: :channel_playlists_filter}),
    do: {"type to filter | Enter/Esc: keep | backspace: edit", :white}

  # The queue-manage modal has its own key set; checked before the view-based
  # clauses because the base view is still whatever it was opened over.
  defp footer_content(%{mode: :queue_manage, queue_return: :playing}),
    do: {"j/k | [/]: move | d: remove | c: clear | Esc: back | q: quit", :white}

  defp footer_content(%{mode: :queue_manage}),
    do: {"j/k | [/]: move | d: remove | c: clear | Enter: play | Esc: back | q: quit", :white}

  defp footer_content(%{mode: :help}),
    do: {"Esc/?: close | q: quit", :white}

  defp footer_content(%{mode: :history}),
    do:
      {"j/k | Enter: play | e: queue | n: play next | d: remove | c: clear | Esc: back | q: quit",
       :white}

  defp footer_content(%{mode: :explore}),
    do:
      {"j/k | Enter: play | b: bookmark | e: queue | n: play next | Esc: back\nQ: queue | H: history | q: quit",
       :white}

  defp footer_content(%{mode: :search_results, search_filter: term}) when term != "",
    do:
      {"filtering \"#{term}\" | /: edit | Esc: clear | j/k | Enter: play\nS: new | Q: queue | H: history | q: quit",
       :white}

  defp footer_content(%{mode: :search_results}),
    do:
      {"j/k | Enter: play | b: bookmark | e: queue | n: play next | /: filter | S: new | Esc: back\nQ: queue | H: history | q: quit",
       :white}

  defp footer_content(%{mode: :playing, playing: %{stage: stage}})
       when stage in [:starting, :resolving, :captions],
       do: {"Preparing playback… | Q: queue", :cyan}

  defp footer_content(%{mode: :playing}),
    do: {"The external player controls playback — close it to return | Q: queue", :cyan}

  defp footer_content(%{mode: :channel_playlists, channel_playlist_filter: term})
       when term != "" do
    {"filtering \"#{term}\" | /: edit | Esc: clear | j/k | Enter: open\np: save | v: videos | s: streams\nS: search | E: explore | Q: queue | H: history | q: quit",
     :white}
  end

  defp footer_content(%{mode: :channel_playlists}) do
    {"j/k | Enter: open | p: save | /: filter | Esc: back\nv: videos | s: streams\nS: search | E: explore | Q: queue | H: history | q: quit",
     :white}
  end

  # With an active filter, base modes surface the clear/edit keys instead of the
  # full hint row (which is otherwise unreachable while filtering matters most).
  # Checked before the per-view footers below, all of which assume no filter.
  defp footer_content(%{filter: term, mode: :videos, view: :locals}) when term != "" do
    {~s(filtering "#{term}" | /: edit | Esc: clear | j/k | Enter: open/play | r: refresh), :white}
  end

  defp footer_content(%{filter: term} = state)
       when term != "" and state.mode in [:list, :videos] do
    {~s(filtering "#{term}" | /: edit | Esc: clear | j/k | Enter: select), :white}
  end

  # Local files can't be bookmarked (no YouTube URL to look up), so its video
  # footer drops the bookmark hint.
  defp footer_content(%{mode: :videos, view: :locals}),
    do:
      video_footer("j/k | Enter: open/play | e: queue file | r: refresh | /: filter | Esc: back")

  # A subscription listing (channel_url set) exposes all three channel tabs.
  defp footer_content(%{mode: :videos, channel_url: url}) when is_binary(url),
    do: channel_video_footer()

  defp footer_content(%{mode: :videos}),
    do:
      video_footer(
        "j/k | Enter: play | b: bookmark | e: queue | n: play next | /: filter | Esc: back"
      )

  defp footer_content(%{view: :bookmarks}),
    do:
      browse_footer(
        "j/k | a: add | d: del | Enter: play | e: queue | n: play next | /: filter",
        "Subscriptions"
      )

  defp footer_content(%{view: :subscriptions}),
    do: browse_footer("j/k | a: add | d: del | Enter: open | /: filter", "Playlists")

  defp footer_content(%{view: :playlists}),
    do: browse_footer("j/k | a: add | d: del | Enter: open | /: filter", "Locals")

  defp footer_content(%{view: :locals}),
    do: browse_footer("j/k | a: add | d: del | Enter: open | /: filter", "Bookmarks")

  defp browse_footer(actions, next_view) do
    {"#{actions}\nS: search | E: explore | Q: queue | H: history | Tab: #{next_view} | ?: help | q: quit",
     :white}
  end

  defp video_footer(actions) do
    {"#{actions}\nS: search | E: explore | Q: queue | H: history | ?: help | q: quit", :white}
  end

  defp channel_video_footer do
    {"j/k | Enter: play | b: bookmark | e: queue | n: play next | /: filter | Esc: back\nv: videos | s: streams | p: playlists\nS: search | E: explore | Q: queue | H: history | ?: help | q: quit",
     :white}
  end

  defp playback_time(milliseconds) when is_integer(milliseconds) and milliseconds >= 0 do
    seconds = div(milliseconds, 1_000)
    hours = div(seconds, 3_600)
    minutes = div(rem(seconds, 3_600), 60)
    seconds = rem(seconds, 60)

    if hours > 0 do
      "#{hours}:#{pad_time(minutes)}:#{pad_time(seconds)}"
    else
      "#{minutes}:#{pad_time(seconds)}"
    end
  end

  defp playback_time(_milliseconds), do: "0:00"
  defp pad_time(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp clamp(n, lo, _hi) when n < lo, do: lo
  defp clamp(n, _lo, hi) when n > hi, do: hi
  defp clamp(n, _lo, _hi), do: n

  # Error reasons often carry multi-line stderr, which is unreadable in the
  # compact footer. Collapse to the first non-blank line and cap its length.
  @error_max_len 120
  defp short_error(msg) when is_binary(msg) do
    first =
      msg
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.find("", &(&1 != ""))

    if String.length(first) > @error_max_len do
      String.slice(first, 0, @error_max_len - 1) <> "…"
    else
      first
    end
  end

  defp short_error(msg), do: to_string(msg)
end
