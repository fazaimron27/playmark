defmodule Playmark.Player.Captions do
  @moduledoc """
  Selects and downloads a YouTube caption track to a temporary sidecar file.

  Captions can't ride along with stream resolution, because the two need
  *different* yt-dlp player clients. The stream client (`web_safari`) returns URLs
  a plain HTTP client can actually fetch, but YouTube discards its caption tracks
  unless a PO token is supplied. The caption client (`default`) exposes the tracks
  with no token, but its stream URLs return `HTTP 403`. So both players resolve
  streams with one client and download captions with another, then hand the
  downloaded `.vtt` to the player as a sidecar (`--sub-file`).

  This is why both `Playmark.Player.Mpv` and `Playmark.Player.Vlc` share this
  module rather than each fetching captions their own way: the mechanism is
  identical, only the stream path differs between the players.

  ## Preference chain

  A single `yt-dlp -J` probe reports the manual (uploader) tracks, the
  auto-generated tracks, and the video's spoken language all at once. From that,
  `select/2` picks the one best track by priority:

    1. a manual track in `opts.subtitle_default`,
    2. else a manual track in `opts.subtitle_fallback` (if configured),
    3. else the auto-generated track in the video's *spoken* language.

  Only the winning track is then downloaded. Probing first (rather than blindly
  attempting each tier) keeps the logic deterministic and avoids downloading a
  track we won't use.

  Captions are best-effort. Any failure — no matching track, a probe/download
  error, a client that returns nothing — resolves to `nil`, and the caller plays
  without captions. A missing caption is never an error.
  """

  require Logger

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
  # Playmark.Playback (a 1-arity fn). Absent (e.g. the debug task builds opts
  # without one) or non-function means no reporting — never a crash.
  defp report_selection(%{progress: fun}, selection) when is_function(fun, 1) do
    fun.({:caption, selection})
    :ok
  end

  defp report_selection(_opts, _selection), do: :ok

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

  Returns `{:manual, exact_key}` or `{:auto, exact_key}` naming the yt-dlp track
  key to download, or `:none` when nothing matches. `probe` is a map with
  `"subtitles"` and `"automatic_captions"` (each a map of lang-key => tracks) and
  a `"language"` (the spoken language, may be `nil`). Exposed for testing.

  Language matching is by prefix so a request for `"en"` accepts `"en"`,
  `"en-US"`, or `"en-orig"` — YouTube's exact key varies.
  """
  def select(probe, opts) do
    manual = Map.get(probe, "subtitles", %{})
    auto = Map.get(probe, "automatic_captions", %{})
    spoken = probe["language"]

    cond do
      key = match_lang(manual, opts.subtitle_default) -> {:manual, key}
      key = match_lang(manual, opts.subtitle_fallback) -> {:manual, key}
      key = match_lang(auto, spoken) -> {:auto, key}
      true -> :none
    end
  end

  # --- internal ------------------------------------------------------------

  # Ask yt-dlp for the full metadata JSON (no download). The caption client is
  # used so caption tracks are actually listed (see moduledoc).
  defp probe(url, opts) do
    args = [
      "--extractor-args",
      "youtube:player_client=#{opts.subtitle_client}",
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

  # The first track key in `tracks` whose language matches `lang` by prefix, or
  # nil. A nil/blank `lang` (e.g. no fallback configured, or unknown spoken
  # language) matches nothing.
  defp match_lang(_tracks, nil), do: nil
  defp match_lang(_tracks, ""), do: nil

  defp match_lang(tracks, lang) do
    tracks
    |> Map.keys()
    |> Enum.sort()
    |> Enum.find(fn key -> key == lang or String.starts_with?(key, lang <> "-") end)
  end

  # Download exactly the selected track. `--write-subs` fetches manual tracks,
  # `--write-auto-subs` the auto-generated ones; we pass the matching flag plus
  # the exact key so yt-dlp writes just the one file.
  defp fetch(url, opts, kind, lang) do
    base = Path.join(System.tmp_dir!(), "playmark-sub-#{System.unique_integer([:positive])}")
    write_flag = if kind == :manual, do: "--write-subs", else: "--write-auto-subs"

    args = [
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
end
