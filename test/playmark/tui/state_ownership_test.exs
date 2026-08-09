defmodule Playmark.TUI.StateOwnershipTest do
  # Enforces the state-key ownership invariant CLAUDE.md publishes.
  #
  # TUI state is one flat map built in `Playmark.TUI.mount/1` — no struct, no
  # typespec — threaded through every module under `tui/`. Any function holding it
  # can write any key, and Elixir will not stop it. The invariant says who *may*:
  # each overlay owns its own keys, and the browse cursor/rows belong to `Actions`
  # and `Filter`. That is a claim about ownership, not type — a typespec would say
  # `:selected` is an integer; this says who is allowed to set it.
  #
  # CLAUDE.md also publishes a grep for it, which only sees `state.key` reads. A
  # write goes through `%{state | selected: 0}`, where the key sits on its own line
  # with no `state.` prefix, so the grep cannot see it. This test parses the AST
  # instead and sees writes, matches, and reads alike.
  #
  # It asserts about source text rather than behaviour, which makes it a heuristic
  # in a way a type checker is not. It earns its place because the alternative —
  # nesting the state map into owned sub-maps so the compiler enforces this — is a
  # rewrite of every module under `tui/` for a property this file can assert
  # directly.
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @overlay_glob Path.join(@root, "lib/playmark/tui/*_actions.ex")
  @tui Path.join(@root, "lib/playmark/tui.ex")
  @claude_md Path.join(@root, "CLAUDE.md")

  # Who owns what. Every key `mount/1` builds appears exactly once below — the
  # first test holds that, so a new state key added without an owner fails here.
  @owners %{
    # The browse core: `Actions` + `Filter`. Cursor, rows, and the navigation
    # state that positions them.
    browse: ~w(videos channel_name channel_url video_tab videos_return
               channel_request_ref channel_task_pid playlist_request_ref
               playlist_task_pid playlist_return loading_return
               local_root local_root_name local_path local_stack local_pending
               local_request_ref local_task_pid
               channel_playlists channel_playlist_selected channel_playlist_filter
               channel_playlist_channel_name channel_playlist_channel_url
               channel_playlists_return channel_playlists_request_ref
               channel_playlists_task_pid channel_playlist_save_ref
               selected filter filter_return)a,
    queue: ~w(queue queue_selected queue_return)a,
    history: ~w(history history_selected history_return)a,
    explore: ~w(explore_videos explore_selected explore_return explore_request_ref
                explore_task_pid)a,
    search: ~w(search_videos search_selected search_query search_filter
               search_return search_request_ref search_task_pid)a,
    help: ~w(help_return)a,
    playback: ~w(playing resume)a,
    # Shared mechanism. `:mode` is *written* by every overlay when it opens or
    # closes itself; the confirm modal and the text input are shared machinery.
    shared: ~w(view mode confirm confirm_return input status)a,
    # DB-backed mirrors of a context. Whichever module writes the table refreshes
    # the list — that is the add path's whole job — so these are not owned. Note
    # `queue` and `history` are deliberately *not* here: their cursor and return
    # mode make them their overlay's, and CLAUDE.md names `queue` as such.
    shared_data: ~w(bookmarks subscriptions locals playlists)a
  }

  @unowned [:shared, :shared_data]

  # The base variables of a `%{x | ...}` update inside an overlay. Only `state` is
  # TUI state; the rest are nested maps state holds. A new name here means a map
  # update this test has not been taught about — see the guard test below.
  @update_bases ~w(state playing captions stream)a

  # The documented exceptions, one entry per numbered item in CLAUDE.md. Keyed by
  # `{file, key, form}` rather than line, so an edit above one does not break this.
  @exceptions [
    %{
      item: 1,
      module: "AddActions",
      accesses: [{"add_actions.ex", :selected, :write}],
      why: """
      handle_result/2's four success clauses switch to the view they added to and
      reset the cursor: a terminal "the add finished, show me the row" commit, not
      ongoing collaboration with the browse cursor.
      """
    },
    %{
      item: 2,
      module: "PlaybackActions",
      accesses: [
        {"playback_actions.ex", :queue, :write},
        {"playback_actions.ex", :queue_selected, :write},
        {"playback_actions.ex", :queue_return, :write},
        {"playback_actions.ex", :queue_return, :dotread},
        {"playback_actions.ex", :history_return, :dotread}
      ],
      why: """
      The queue-origin result clauses and complete_queued_play/1 advance or halt
      the queue, and return_mode/2 maps a play's origin to that overlay's saved
      return mode — which means reading queue_return and history_return. The
      coupling predates the split.
      """
    },
    %{
      item: 3,
      module: "PlaybackActions",
      accesses: [{"playback_actions.ex", :videos, :match}],
      why: """
      play_return_mode/1's middle clause is a legacy fallback for older/forced test
      states, kept next to the return_mode/2 it partly duplicates.
      """
    }
  ]

  @allowlist Enum.flat_map(@exceptions, & &1.accesses)

  describe "the state map mount/1 builds" do
    test "gives every one of its keys exactly one owner" do
      unassigned = MapSet.difference(state_keys(), assigned_keys())

      assert MapSet.size(state_keys()) > 0, "derived no state keys from #{@tui}"

      assert Enum.empty?(unassigned), """
      mount/1 builds state keys that @owners does not assign:

        #{unassigned |> Enum.sort() |> Enum.map_join("\n  ", &inspect/1)}

      Add each to the owner that writes it, or to :shared / :shared_data with a
      reason. An unowned key is a key this test cannot police.
      """
    end

    test "defines every key the owner table names" do
      phantom = MapSet.difference(assigned_keys(), state_keys())

      assert Enum.empty?(phantom), """
      @owners names keys mount/1 no longer builds:

        #{phantom |> Enum.sort() |> Enum.map_join("\n  ", &inspect/1)}

      Drop them — a stale entry silently widens what this test permits.
      """
    end
  end

  describe "ownership across the overlay modules" do
    test "finds the overlay modules, and only them" do
      names = @overlay_glob |> Path.wildcard() |> Enum.map(&Path.basename/1)

      assert names == ~w(add_actions.ex explore_actions.ex help_actions.ex
                         history_actions.ex playback_actions.ex queue_actions.ex
                         search_actions.ex)

      # actions.ex and filter.ex are the browse core itself — the owners, not
      # overlays. A glob that swept them in would report the invariant as violated
      # by the module that defines it.
      refute "actions.ex" in names
      refute "filter.ex" in names
    end

    test "reads real state accesses out of every one of them" do
      # Guards the way this test most plausibly fails: passing because it parsed
      # nothing and therefore found nothing.
      for path <- Path.wildcard(@overlay_glob) do
        writes =
          Enum.filter(accesses(path), fn {form, _line, base, _key} ->
            form == :write and base == :state
          end)

        assert writes != [], "found no %{state | ...} writes in #{path}"
      end
    end

    test "no overlay touches a key it does not own, beyond the documented exceptions" do
      found = Enum.flat_map(Path.wildcard(@overlay_glob), &cross_owner_accesses/1)

      unexpected =
        Enum.reject(found, fn {file, _line, key, form, _owner} ->
          {file, key, form} in @allowlist
        end)

      assert unexpected == [], """
      An overlay module touched a state key another module owns:

      #{Enum.map_join(unexpected, "\n", &format_access/1)}

      Each overlay owns only its own keys (see CLAUDE.md's TUI section). If this
      access is deliberate, add it to @exceptions here *and* to CLAUDE.md's
      numbered list — the sync test below fails until both agree.
      """
    end

    test "every documented exception is still a real access" do
      found =
        Path.wildcard(@overlay_glob)
        |> Enum.flat_map(&cross_owner_accesses/1)
        |> Enum.map(fn {file, _line, key, form, _owner} -> {file, key, form} end)
        |> MapSet.new()

      stale = Enum.reject(@allowlist, &MapSet.member?(found, &1))

      assert stale == [], """
      @exceptions allows accesses that no longer happen:

        #{Enum.map_join(stale, "\n  ", &inspect/1)}

      The code got stricter than its documentation. Drop these here and renumber
      CLAUDE.md's list — a stale allowance quietly permits a future regression.
      """
    end
  end

  describe "the assumptions this walk rests on" do
    test "state is only ever updated through %{state | ...}" do
      offenders =
        for path <- Path.wildcard(@overlay_glob),
            {line, number} <- Enum.with_index(File.stream!(path), 1),
            Regex.match?(~r/Map\.(put|merge|replace!?|update!?)\(\s*state\b/, line),
            do: "  #{Path.relative_to(path, @root)}:#{number}  #{String.trim(line)}"

      assert offenders == [], """
      State was updated by a Map call this test cannot attribute to a key:

      #{Enum.join(offenders, "\n")}

      The AST walk recognises `%{state | key: value}`. Keep writes in that shape,
      or teach `accesses/1` the new one.
      """
    end

    test "recognises every map-update base variable in play" do
      bases =
        for path <- Path.wildcard(@overlay_glob),
            {:write, _line, base, _key} <- accesses(path),
            into: MapSet.new(),
            do: base

      unknown = bases |> MapSet.difference(MapSet.new(@update_bases)) |> Enum.sort()

      assert unknown == [], """
      New base variables appear in `%{x | ...}` updates: #{inspect(unknown)}

      Only `state` carries TUI state; the others are nested maps it holds. If one
      of these *is* state under another name, this test has been silently blind to
      its writes — rename it to `state` or extend @update_bases deliberately.
      """
    end
  end

  describe "CLAUDE.md" do
    test "documents exactly as many exceptions as the allowlist grants" do
      items = documented_exceptions()

      assert length(items) == length(@exceptions), """
      CLAUDE.md lists #{length(items)} exceptions; @exceptions holds #{length(@exceptions)}.

      The code and its documentation disagree about what is permitted. Update
      whichever is behind.
      """
    end

    test "spells the count the same way in the prose around the list" do
      count = length(@exceptions)
      word = Enum.at(~w(zero one two three four five six seven eight nine), count)
      body = File.read!(@claude_md)

      assert body =~ ~r/#{word} deliberate exceptions therefore exist/i, """
      CLAUDE.md's lead-in does not say "#{word} deliberate exceptions therefore
      exist". The numbered list and the sentence introducing it have drifted.
      """

      assert body =~ ~r/beyond these #{word} is a violation/i, """
      CLAUDE.md's closing line does not say "beyond these #{word} is a violation".
      """
    end

    test "names the module behind each exception in the matching item" do
      items = documented_exceptions()

      for %{item: number, module: module} <- @exceptions do
        text = Enum.at(items, number - 1) || ""

        assert text =~ module, """
        CLAUDE.md exception #{number} does not mention `#{module}`, which is the
        module @exceptions attributes it to. The lists are out of order or out of
        sync.

        Item #{number} reads: #{text}
        """
      end
    end
  end

  # --- deriving the state keys ----------------------------------------------

  # The state map is one flat literal in `mount/1`. Derive its keys rather than
  # restating them here, so this test tracks the real thing.
  defp state_keys do
    {_, keys} =
      @tui
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk(nil, fn
        {:def, _meta, [{:mount, _, _} | _]} = node, nil -> {node, first_map_keys(node)}
        node, acc -> {node, acc}
      end)

    MapSet.new(keys || [])
  end

  defp first_map_keys(ast) do
    {_, keys} =
      Macro.prewalk(ast, nil, fn
        {:%{}, _meta, pairs} = node, nil when is_list(pairs) ->
          {node, for({key, _value} <- pairs, is_atom(key), do: key)}

        node, acc ->
          {node, acc}
      end)

    keys
  end

  defp assigned_keys, do: @owners |> Map.values() |> List.flatten() |> MapSet.new()

  defp owner_of(key) do
    Enum.find_value(@owners, :unknown, fn {owner, keys} -> if key in keys, do: owner end)
  end

  # add_actions.ex -> :add, matching the @owners keys.
  defp overlay_of(path) do
    path
    |> Path.basename(".ex")
    |> String.replace_suffix("_actions", "")
    |> String.to_atom()
  end

  # --- the walk --------------------------------------------------------------

  # Every state access in one file, as {form, line, base_var, key}:
  #
  #   :write    %{state | key: value}
  #   :match    %{key: value} — a pattern in a function head, or a map being built
  #   :dotread  state.key
  #
  # The :match form cannot tell a pattern from a construction without semantic
  # analysis, and does not try. Filtering to keys `mount/1` actually defines is
  # what keeps it quiet: `%{title: t, url: u}` and `%{action: a, prompt: p}` are
  # ordinary payload maps, and none of their keys are state keys.
  defp accesses(path) do
    {_, found} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:%{}, meta, [{:|, _, [{base, _, context}, pairs]}]} = node, acc
        when is_atom(context) and is_list(pairs) ->
          {node, key_accesses(pairs, :write, meta, base) ++ acc}

        {:%{}, meta, pairs} = node, acc when is_list(pairs) ->
          {node, key_accesses(pairs, :match, meta, :state) ++ acc}

        {{:., _, [{base, _, context}, key]}, meta, []} = node, acc
        when is_atom(context) and is_atom(key) ->
          {node, [{:dotread, meta[:line], base, key} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp key_accesses(pairs, form, meta, base) do
    for {key, _value} <- pairs, is_atom(key), do: {form, meta[:line], base, key}
  end

  # The accesses in one overlay that name a state key belonging to someone else.
  defp cross_owner_accesses(path) do
    mine = overlay_of(path)
    keys = state_keys()

    for {form, line, base, key} <- accesses(path),
        form == :match or base == :state,
        MapSet.member?(keys, key),
        owner = owner_of(key),
        owner not in @unowned,
        owner != mine,
        do: {Path.basename(path), line, key, form, owner}
  end

  defp format_access({file, line, key, form, owner}) do
    "  lib/playmark/tui/#{file}:#{line}  #{form} :#{key} — owned by :#{owner}"
  end

  # --- reading the documentation --------------------------------------------

  # The numbered list under "deliberate exceptions therefore exist", as raw text.
  defp documented_exceptions do
    @claude_md
    |> File.read!()
    |> String.split(~r/deliberate exceptions therefore exist[^\n]*\n/, parts: 2)
    |> case do
      [_before, rest] ->
        rest
        |> String.split("\n")
        |> Enum.take_while(&(not Regex.match?(~r/^\s*Anything beyond/, &1)))
        |> Enum.filter(&Regex.match?(~r/^\s*\d+\.\s/, &1))
        |> Enum.map(&String.trim/1)

      _missing ->
        []
    end
  end
end
