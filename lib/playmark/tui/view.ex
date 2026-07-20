defmodule Playmark.TUI.View do
  @moduledoc """
  Pure rendering for `Playmark.TUI`: turns UI state into a list of
  `{widget, rect}` tuples. No side effects and no state transitions live here —
  everything is a function of the state map handed in by the runtime.

  The layout gains a dedicated input row while adding (`:input`/`:fetching`);
  every other mode uses the three-row header/body/footer split.
  """

  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, Paragraph, Table, TextInput}

  def render(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    if state.mode in [:input, :fetching] do
      [header_area, body_area, input_area, footer_area] =
        Layout.split(area, :vertical, [{:length, 3}, {:min, 0}, {:length, 3}, {:length, 3}])

      [
        {header(state), header_area},
        {body(state), body_area},
        {input_widget(state), input_area},
        {footer(state), footer_area}
      ]
    else
      [header_area, body_area, footer_area] =
        Layout.split(area, :vertical, [{:length, 3}, {:min, 0}, {:length, 3}])

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

  # The queue-manage modal names itself, whatever base view it was opened over.
  defp section(%{mode: :queue_manage}), do: "Queue"

  # While browsing a channel's videos — or playing one launched from that list —
  # show the channel name, matching the video-list body (see showing_videos?/1).
  defp section(%{channel_name: name} = state) when name != nil do
    if showing_videos?(state), do: name, else: view_section(state)
  end

  defp section(state), do: view_section(state)

  defp view_section(%{view: :bookmarks}), do: "Bookmarks"
  defp view_section(%{view: :subscriptions}), do: "Subscriptions"
  defp view_section(%{view: :search}), do: "Search"
  defp view_section(%{view: :local}), do: "Local"

  # The body renders whichever list the selection points into. The video list
  # is shown while browsing a channel's videos AND while a video launched from
  # that list is playing, so the screen behind the player stays on the video
  # list instead of flipping back to the subscriptions list (see
  # showing_videos?/1). Otherwise the active view decides.
  defp body(state) do
    cond do
      state.mode == :queue_manage ->
        queue_body(state)

      state.mode == :playing ->
        now_playing(state)

      showing_videos?(state) ->
        {title, empty_text} = videos_labels(state)

        table_or_empty(
          Enum.map(state.videos, &[&1.title]),
          ["Title"],
          [{:percentage, 100}],
          state.selected,
          title,
          empty_text
        )

      state.view == :bookmarks ->
        table_or_empty(
          Enum.map(state.bookmarks, &[&1.title, &1.channel]),
          ["Title", "Channel"],
          [{:percentage, 65}, {:percentage, 35}],
          state.selected,
          " Bookmarks ",
          "No bookmarks yet.\n\nPress \"a\" to add one, or Tab for subscriptions."
        )

      state.view == :subscriptions ->
        table_or_empty(
          Enum.map(state.subscriptions, &[&1.name, &1.url]),
          ["Channel", "URL"],
          [{:percentage, 40}, {:percentage, 60}],
          state.selected,
          " Subscriptions ",
          "No subscriptions yet.\n\nPress \"a\" to add a channel, or Tab for bookmarks."
        )

      state.view == :local ->
        table_or_empty(
          Enum.map(state.playlists, &[&1.name, &1.path]),
          ["Name", "Directory"],
          [{:percentage, 40}, {:percentage, 60}],
          state.selected,
          " Local ",
          "No local playlists yet.\n\nPress \"a\" to register a directory, or Tab for bookmarks."
        )

      # Search holds no list in :list mode — results arrive in :videos mode,
      # handled by the showing_videos?/1 branch above. Idle, it's just a prompt.
      true ->
        table_or_empty(
          [],
          ["Title"],
          [{:percentage, 100}],
          state.selected,
          " Search ",
          "Search YouTube.\n\nPress \"/\" to enter a query, or Tab for bookmarks."
        )
    end
  end

  # The queue-manage modal's body: the upcoming items with a Source column
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

  defp queue_source(%{local: true}), do: "local"
  defp queue_source(_item), do: "YouTube"

  # True while browsing a channel's video list, and while a video launched from
  # that list is playing — so both the body and header keep showing the video
  # list instead of the subscriptions list underneath the player.
  defp showing_videos?(%{mode: :videos}), do: true
  defp showing_videos?(%{mode: :playing, videos: videos}), do: videos != []
  defp showing_videos?(_state), do: false

  # The "Now playing" panel shown in :playing mode: the video title on top, then
  # the ordered steps for this play (seeded in Playmark.TUI.Actions) as a checklist
  # that advances as the backend reports each stage. During :resolving/:captions
  # the external player hasn't taken the screen yet, so this panel is what the user
  # sees; once mpv/VLC launches it covers the terminal until it closes.
  defp now_playing(%{playing: %{} = playing}) do
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

    "#{playing.title}\n\nin #{playing.player}\n\n#{checklist}"
  end

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

  # The stream step (VLC only) carries detail beyond a bare label: the quality
  # cap it's resolving under (the configured :max_height), and — once yt-dlp has
  # returned URLs — the resolved shape: a split video+audio pair (recombined for
  # the player) or a single muxed stream. `stream.result` is nil until VLC reports.
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

  # After resolution: the concrete track that won the preference chain.
  defp caption_detail(%{result: {:manual, key}}), do: "#{lang(key)}, uploader-provided"
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

  # The video list is shared between a subscription's latest videos and search
  # results; the active view says which, so the table title matches the header.
  defp videos_labels(%{view: :search}), do: {" Search results ", "No results."}
  defp videos_labels(%{view: :local}), do: {" Files ", "No media files in this directory."}
  defp videos_labels(_state), do: {" Latest videos ", "No videos in this channel."}

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

  defp input_labels(:subscriptions),
    do: {" Add subscription — paste a channel URL ", "https://www.youtube.com/@handle/videos"}

  defp input_labels(:search),
    do: {" Search YouTube — type a query ", "today's news"}

  defp input_labels(:local),
    do: {" Register directory — type a path ", "~/Videos"}

  defp input_labels(_bookmarks),
    do: {" Add bookmark — paste a YouTube URL ", "https://www.youtube.com/watch?v=…"}

  defp fetching_text(%{view: :subscriptions}), do: "Adding channel… (Esc to cancel)"
  defp fetching_text(%{view: :local}), do: "Registering directory… (Esc to cancel)"
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

  # A status message (success or error) always wins over the mode hints.
  defp footer_content(%{status: {:error, msg}}), do: {msg, :red}
  defp footer_content(%{status: {:info, msg}}), do: {msg, :green}
  defp footer_content(%{mode: :input}), do: {"Enter: add | Esc: cancel", :white}
  defp footer_content(%{mode: :fetching}), do: {"Working… (Esc to cancel)", :cyan}
  defp footer_content(%{mode: :loading}), do: {"Loading… (Esc to cancel)", :cyan}

  # The queue-manage modal has its own key set; checked before the view-based
  # clauses because the base view is still whatever it was opened over.
  defp footer_content(%{mode: :queue_manage}),
    do: {"j/k | [/]: move | d: remove | c: clear | Enter: play | Esc: back", :white}

  defp footer_content(%{mode: :playing}),
    do: {"The player controls playback — close it to return | Q: queue", :cyan}

  # Local files can't be bookmarked (no YouTube URL to look up), so its video
  # footer drops the bookmark hint.
  defp footer_content(%{mode: :videos, view: :local}),
    do: {"j/k | Enter: play | e: queue | Q: manage | Esc: back | q: quit", :white}

  defp footer_content(%{mode: :videos}),
    do: {"j/k | Enter: play | b: bookmark | e: queue | Q: manage | Esc: back | q: quit", :white}

  defp footer_content(%{view: :bookmarks}),
    do:
      {"j/k | a: add | d: del | Enter: play | e: queue | Q: manage | Tab: subs | q: quit", :white}

  defp footer_content(%{view: :subscriptions}),
    do: {"j/k | a: add | d: delete | Enter: open | Q: queue | Tab: search | q: quit", :white}

  defp footer_content(%{view: :search}),
    do: {"/: search | Q: queue | Tab: local | q: quit", :white}

  defp footer_content(%{view: :local}),
    do:
      {"j/k | a: add | d: del | Enter: open | e: queue | Q: manage | Tab: bookmarks | q: quit",
       :white}

  defp clamp(n, lo, _hi) when n < lo, do: lo
  defp clamp(n, _lo, hi) when n > hi, do: hi
  defp clamp(n, _lo, _hi), do: n
end
