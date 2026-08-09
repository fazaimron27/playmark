defmodule Playmark.Player.Captions do
  @moduledoc """
  Selects and downloads a YouTube caption track to a temporary sidecar file.

  Captions can't ride along with stream resolution, because the two need
  *different* yt-dlp player clients. The stream client (`web_safari`) returns URLs
  a plain HTTP client can actually fetch, but YouTube discards its caption tracks
  unless a PO token is supplied. The caption client (`default`) exposes the tracks
  with no token, but its stream URLs return `HTTP 403`. So the caption-capable
  mpv and VLC backends resolve streams with one client and download captions
  with another, then hand the downloaded `.vtt` to the player as a sidecar
  (`--sub-file`). ffplay deliberately skips this path.

  This is why both `Playmark.Player.Mpv` and `Playmark.Player.Vlc` share this
  module rather than each fetching captions their own way: the mechanism is
  identical, only the stream path differs between the players.

  ## Preference chain

  A single `yt-dlp -J` probe reports the manual (uploader) tracks, the
  auto-generated tracks, and the video's spoken language all at once. From that,
  `select/2` picks the one best track by priority:

    1. a manual track in `opts.subtitle_default`,
    2. else a translation into `opts.subtitle_default`,
    3. else a manual track in `opts.subtitle_fallback` (if configured),
    4. else a translation into `opts.subtitle_fallback`,
    5. else the auto-generated track in the video's *spoken* language.

  The chain is ordered by **language first, quality second**: a translation into
  the first-choice language outranks a human-made track in the second-choice one.
  A user who lists two languages is ranking them, so a Korean podcast with
  uploader English subs yields Indonesian for `subtitle_default = id,
  subtitle_fallback = en`. Set `subtitle_translate = false` to drop tiers 2 and 4
  and get the uploader's English instead.

  Only the winning track is then downloaded. Probing first (rather than blindly
  attempting each tier) keeps the logic deterministic and avoids downloading a
  track we won't use.

  ## Machine translation (tiers 2 and 4)

  YouTube's `automatic_captions` map holds far more than the spoken language: for
  every translatable track it lists that track machine-translated into ~150 target
  languages. Each is an ordinary key, downloadable through the same
  `--write-auto-subs --sub-langs <key>` call as any other auto track — no extra
  request, no different client. There are two shapes, and they behave differently:

    * **ASR-source** — a translation of the auto-generated transcript, keyed
      plainly (`id`, `en`). Present whenever the video has ASR captions.
    * **Manual-source** — a translation of an *uploader* track, keyed
      `{target}-{source}` (`id-en` is "Indonesian from English"). This is what the
      web player's "auto-translate" does to a manual track, and on a video with no
      ASR track it is the *only* way to reach a translation.

  Manual-source keys are why `probe/2` passes `--write-auto-subs` (see there).
  When one requested language is available from several sources, `source_rank/3`
  prefers an uploader track the user reads over one they don't, and any uploader
  track over an ASR-derived one — a human rendering is a better input to machine
  translation than a speech-recognition guess, and the user can sanity-check a
  line that comes out strange.

  Such a track is tagged `:translated` rather than `:auto` because it is a
  translation *of* a transcript — for the ASR-source shape, two lossy passes — and
  the UI says so. A track in the requested language that happens to *be* the
  native ASR track keeps the plain `:auto` tag.

  Because nearly every video offers every target language, these tiers would leave
  the spoken-language tier unreachable, so `opts.subtitle_translate` turns them off
  for users who want the original transcript (language learners, or anyone who
  reads the spoken language).

  Captions are best-effort. Any failure — no matching track, a probe/download
  error, a client that returns nothing — resolves to `nil`, and the caller plays
  without captions. A missing caption is never an error.
  """

  require Logger

  # Bounds each yt-dlp socket read/connect so a black-holed network can't hang
  # caption probe/download forever (matching Playmark.Source.Channel). Captions are
  # best-effort, so on timeout yt-dlp errors and the video just plays without one.
  # User-overridable via the :socket_timeout config key (see Playmark.Config).
  @default_socket_timeout 30

  @doc """
  Downloads the best caption track for `url` and returns the path to a temp
  `.vtt`, or `nil` if none is available.

  Probes with `opts.subtitle_client` (the caption-capable client), picks a track
  via the preference chain (`opts.subtitle_default`, `opts.subtitle_fallback`,
  then auto in the spoken language), and downloads exactly that track. The caller
  owns the returned file and must delete it when playback ends (see `cleanup/1`).
  """
  def download(url, opts) when is_binary(url) do
    case probe(url, opts) do
      {:ok, probe} ->
        selection = select(probe, opts)
        # Tell the UI what the preference chain resolved to (language + whether
        # it's an uploader or auto-generated track, or that none matched) before
        # the actual fetch, so the "Captions" step can show the concrete result.
        report_selection(opts, selection)
        # The same probe already carries the video's chapter list, so report its
        # count for the Now Playing panel at no extra yt-dlp cost.
        report_chapters(opts, chapters(probe))

        case selection do
          {kind, lang} -> fetch(url, opts, kind, lang)
          :none -> nil
        end

      :error ->
        report_selection(opts, :none)
        nil
    end
  end

  # Best-effort progress: reuse the reporter threaded through opts by
  # Playmark.Player.Playback (a 1-arity fn). Absent (e.g. the debug task builds opts
  # without one) or non-function means no reporting — never a crash.
  defp report_selection(%{progress: fun}, selection) when is_function(fun, 1) do
    fun.({:caption, selection})
    :ok
  end

  defp report_selection(_opts, _selection), do: :ok

  # Best-effort chapter reporting, mirroring report_selection/2: reuse the same
  # progress reporter. Absent or non-function means no reporting.
  defp report_chapters(%{progress: fun}, count) when is_function(fun, 1) do
    fun.({:chapters, count})
    :ok
  end

  defp report_chapters(_opts, _count), do: :ok

  @doc """
  Runs the metadata probe and returns `{:ok, json}` or `:error`. Exposed for the
  `mix playmark.debug --subs` diagnostic, which reports the selected tier without
  downloading; normal playback goes through `download/2`.
  """
  def probe_for_debug(url, opts) when is_binary(url), do: probe(url, opts)

  @doc """
  Deletes a downloaded caption file. A `nil` path is a no-op.
  """
  def cleanup(nil), do: :ok
  def cleanup(path) when is_binary(path), do: File.rm(path)

  @doc """
  Picks the best caption track from a probe result, given the preference chain.

  Returns `{:manual, exact_key}`, `{:translated, exact_key}`, or `{:auto,
  exact_key}` naming the yt-dlp track key to download, or `:none` when nothing
  matches. `probe` is a map with `"subtitles"` and `"automatic_captions"` (each a
  map of lang-key => tracks) and a `"language"` (the spoken language, may be
  `nil`). Exposed for testing.

  Language matching is by prefix so a request for `"en"` accepts `"en"`,
  `"en-US"`, or `"en-orig"` — YouTube's exact key varies.

  When several tracks satisfy the requested language — YouTube offers a
  translation *per source track*, keyed `{target}-{source}` — the one with the
  most trustworthy source wins: an uploader track in a language the user reads,
  then any other uploader track, then an ASR-derived one.

  A `{target}-{source}` key whose source names a real uploader track is always
  tagged `:translated`. Otherwise the tag follows the language: matching the
  spoken language means the native ASR track (`:auto`), differing or unknown
  means `:translated` — the honest label, since we can't show it is native.
  """
  def select(probe, opts) do
    manual = Map.get(probe, "subtitles", %{})
    auto = Map.get(probe, "automatic_captions", %{})
    spoken = probe["language"]

    cond do
      key = match_lang(manual, opts.subtitle_default) -> {:manual, key}
      hit = requested_auto(auto, manual, opts.subtitle_default, spoken, opts) -> hit
      key = match_lang(manual, opts.subtitle_fallback) -> {:manual, key}
      hit = requested_auto(auto, manual, opts.subtitle_fallback, spoken, opts) -> hit
      key = match_lang(auto, spoken) -> {:auto, key}
      true -> :none
    end
  end

  @doc """
  Counts the chapters in a probe result.

  The `yt-dlp -J` probe carries a top-level `"chapters"` array
  (`[%{"start_time", "end_time", "title"}, …]`) alongside the caption tracks, so
  the count is free from the probe already run for captions. Returns `0` when the
  key is absent, empty, or not a list — a video without chapters, or an older
  probe shape, never crashes. Purely informational: the count is surfaced in the
  Now Playing panel; playback does no chapter seeking (mpv navigates them
  natively; VLC/ffplay get pre-resolved URLs). Exposed for testing.
  """
  def chapters(probe) when is_map(probe) do
    case Map.get(probe, "chapters") do
      list when is_list(list) -> length(list)
      _ -> 0
    end
  end

  # --- internal ------------------------------------------------------------
  # Ask yt-dlp for the full metadata JSON (no download). The caption client is
  # used so caption tracks are actually listed (see moduledoc).
  #
  # --write-auto-subs is load-bearing *here*, on a probe that downloads nothing.
  # yt-dlp gates translations-of-a-manual-track behind that flag ("Constructing
  # the full subtitle dictionary is slow" — youtube/_video.py), so without it a
  # video whose only tracks are uploader-provided reports a nearly empty
  # automatic_captions and every `{target}-{source}` key is invisible. Measured on
  # a manual-subs-only video: 2 keys without the flag, 314 with. The probe is
  # network-bound, so the extra JSON costs no measurable time.
  defp probe(url, opts) do
    args = [
      "--socket-timeout",
      socket_timeout(),
      "--extractor-args",
      "youtube:player_client=#{opts.subtitle_client}",
      "--write-auto-subs",
      "--skip-download",
      "-J",
      url
    ]

    case System.cmd("yt-dlp", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> :error
        end

      {output, _code} ->
        Logger.debug("playmark: subtitle probe failed: #{output}")
        :error
    end
  end

  # An auto-track match in a language the *user asked for*, which YouTube may only
  # be able to serve as a machine translation. Returns the already-tagged result
  # (so select/2's cond can hand it straight back), or nil for no match. Gated on
  # :subtitle_translate: with the tier off this yields nil and selection falls
  # through to the spoken-language track.
  #
  # YouTube keys a translation of an *uploader* track as `{target}-{source}`
  # (`id-en` = "Indonesian from English"), so one requested language can be on
  # offer from several sources; source_rank/3 picks between them.
  defp requested_auto(auto, manual, lang, spoken, opts) do
    if opts.subtitle_translate do
      case best_track(auto, manual, lang, spoken) do
        nil -> nil
        key -> {auto_kind(key, manual, spoken), key}
      end
    end
  end

  # The best track in `auto` for the requested `lang`: candidates ranked by
  # source, ties broken by the sort order match_lang/2 would have used, so a
  # single-candidate language behaves exactly as before.
  defp best_track(auto, manual, lang, spoken) do
    auto
    |> Map.keys()
    |> Enum.filter(&lang_matches?(&1, lang))
    |> Enum.sort_by(&{source_rank(&1, manual, spoken), &1})
    |> List.first()
  end

  # How much we trust a translation's source, lower being better. The source is
  # the `-suffix` of a `{target}-{source}` key; a plain key has no suffix and is
  # ASR-derived (or the track itself).
  #
  #   0. an uploader track in a language the user reads — they can sanity-check a
  #      line that comes out strange, and a human rendering is a better input to
  #      machine translation than a speech-recognition guess.
  #   1. any other uploader track (still human-made, just not one they read).
  #   2. no identifiable manual source: ASR-derived, two lossy passes.
  #
  # `-orig` is yt-dlp's own marker for an original-language ASR track, not a
  # source language, so it never counts as manual.
  defp source_rank(key, manual, spoken) do
    case source_of(key) do
      nil -> 2
      source -> if manual_source?(manual, source), do: readable_rank(source, spoken), else: 2
    end
  end

  # A manual source the user reads outranks one they don't. `spoken` stands in for
  # "the language they'd have gotten anyway" — preferring a *different* source is
  # what makes id-en beat id-ko on a Korean video with English subs.
  defp readable_rank(source, spoken) do
    if lang_matches?(source, spoken), do: 1, else: 0
  end

  defp source_of(key) do
    case String.split(key, "-", parts: 2) do
      [_target, source] when source != "" and source != "orig" -> source
      _ -> nil
    end
  end

  defp manual_source?(manual, source) do
    Enum.any?(Map.keys(manual), &lang_matches?(&1, source))
  end

  # Whether a matched auto track is a translation or the video's own ASR
  # transcript.
  #
  # A `{target}-{source}` key whose source is a real uploader track is always a
  # translation, however its target compares to the spoken language — without this
  # clause `en-ko` ("English from Korean") on an English-spoken video would match
  # the `en-` prefix and be mislabelled native. Everything else is judged by
  # language: same as spoken means the native ASR track, differing (or unknown)
  # means we can't call it native, so it reports as translated. Regional variants
  # keep working — `en-US` has no matching source track, so it falls through to
  # the language comparison and stays `:auto`.
  defp auto_kind(key, manual, spoken) do
    cond do
      translated_from_manual?(key, manual) -> :translated
      lang_matches?(key, spoken) -> :auto
      true -> :translated
    end
  end

  defp translated_from_manual?(key, manual) do
    case source_of(key) do
      nil -> false
      source -> manual_source?(manual, source)
    end
  end

  # The first track key in `tracks` whose language matches `lang` by prefix, or
  # nil. A nil/blank `lang` (e.g. no fallback configured, or unknown spoken
  # language) matches nothing.
  defp match_lang(_tracks, nil), do: nil
  defp match_lang(_tracks, ""), do: nil

  defp match_lang(tracks, lang) do
    tracks
    |> Map.keys()
    |> Enum.sort()
    |> Enum.find(&lang_matches?(&1, lang))
  end

  # Prefix language matching, shared by match_lang/2 and auto_kind/2 so a track
  # key is compared to a requested language and to the spoken language the same
  # way: "en" accepts "en", "en-US", "en-orig".
  defp lang_matches?(_key, nil), do: false
  defp lang_matches?(_key, ""), do: false
  defp lang_matches?(key, lang), do: key == lang or String.starts_with?(key, lang <> "-")

  # Download exactly the selected track. `--write-subs` fetches manual tracks,
  # `--write-auto-subs` the auto-generated ones — including `:translated`, which
  # YouTube serves as an ordinary automatic_captions entry, so it needs no special
  # flag. We pass the matching flag plus the exact key so yt-dlp writes one file.
  defp fetch(url, opts, kind, lang) do
    base = Path.join(System.tmp_dir!(), "playmark-sub-#{System.unique_integer([:positive])}")
    write_flag = if kind == :manual, do: "--write-subs", else: "--write-auto-subs"

    args = [
      "--socket-timeout",
      socket_timeout(),
      "--extractor-args",
      "youtube:player_client=#{opts.subtitle_client}",
      write_flag,
      "--sub-langs",
      lang,
      "--sub-format",
      "vtt",
      "--skip-download",
      "-o",
      base,
      url
    ]

    case System.cmd("yt-dlp", args, stderr_to_stdout: true) do
      {_output, 0} ->
        find_written(base)

      {output, _code} ->
        Logger.debug("playmark: subtitle download failed: #{output}")
        nil
    end
  end

  # yt-dlp appends ".<lang>.vtt" to our template; match whatever file it actually
  # produced (the tag can differ from what we asked for, e.g. "en" vs "en-US").
  defp find_written(base) do
    dir = Path.dirname(base)
    prefix = Path.basename(base)

    with {:ok, entries} <- File.ls(dir),
         name when not is_nil(name) <-
           Enum.find(
             entries,
             &(String.starts_with?(&1, prefix) and String.ends_with?(&1, ".vtt"))
           ) do
      Path.join(dir, name)
    else
      _ -> nil
    end
  end

  # yt-dlp socket timeout as a string arg (shared :socket_timeout key, default
  # @default_socket_timeout — see Playmark.Config and Playmark.Source.Channel).
  defp socket_timeout,
    do: to_string(Application.get_env(:playmark, :socket_timeout, @default_socket_timeout))
end
