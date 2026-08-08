defmodule Mix.Tasks.Playmark.Debug do
  @moduledoc """
  Diagnoses playback for a single YouTube URL, outside the TUI.

      # Probe mode (default): which yt-dlp player client yields fetchable URLs?
      mix playmark.debug https://www.youtube.com/watch?v=UokV7Bi3yss

      # Play mode: run the REAL VLC playback command with verbose logging,
      # streamed live with elapsed timestamps, so a mid-stream death is visible.
      mix playmark.debug --play https://www.youtube.com/watch?v=UokV7Bi3yss

      # Mem mode: report the BEAM's memory footprint. With no URL it prints the
      # started-app baseline; with a channel URL it loads that channel the way
      # the TUI does and reports the delta, then reloads it warm to show the
      # title cache (Playmark.Cache) serving titles from ETS instead of oEmbed.
      mix playmark.debug --mem
      mix playmark.debug --mem https://www.youtube.com/@SomeChannel

  Probe mode tries several yt-dlp "player client" strategies. For each, it
  resolves the stream URL(s) and probes each exactly as VLC would — a ranged GET
  with VLC's User-Agent — reporting the real HTTP status. YouTube binds some
  stream URLs (e.g. the TV client's) to the client that requested them, so VLC
  gets a 403 and exits immediately ("opens then closes"). This finds a strategy
  whose URLs VLC can actually fetch.

  Play mode is for the *other* failure: VLC plays for a while, then closes on its
  own. A one-byte probe can't catch that — it needs the real player running. This
  launches VLC with the same stream URL layout as normal playback, plus `-vv`,
  but without caption or display-metadata flags. It prefixes each log line with
  seconds-since-launch so you can see what VLC reports at the moment it dies.

  `Playmark.Playback` uses the `web_safari` client; this task is what identified
  it, and stays around for re-diagnosing new failures.
  """
  @shortdoc "Diagnose playback for one URL"

  use Mix.Task

  alias Playmark.Playback

  # yt-dlp resolves URLs through a chosen YouTube "player client". Each ships
  # differently-signed URLs; some reject non-matching HTTP clients like VLC.
  @clients [
    "default (no override)",
    "web",
    "web_safari",
    "mweb",
    "ios",
    "android",
    "tv"
  ]

  # What VLC sends when it opens an HTTP stream.
  @vlc_user_agent "VLC/3.0.23 LibVLC/3.0.23"

  # The clients Playmark.Playback uses; play/subs modes mirror them exactly.
  # web_safari resolves fetchable streams but drops captions; default exposes
  # captions but its stream URLs 403 — so the two are separate.
  @player_client "web_safari"
  @subtitle_client "default"

  @impl true
  def run(argv) do
    case argv do
      ["--play", url | _] ->
        Application.ensure_all_started(:playmark)
        play_mode(url)

      ["--mem" | rest] ->
        Application.ensure_all_started(:playmark)
        mem_mode(List.first(rest))

      ["--subs", url | _] ->
        Application.ensure_all_started(:playmark)
        subs_mode(url)

      [url | _] when url not in ["--play", "--subs"] ->
        Application.ensure_all_started(:playmark)
        diagnose(url)

      _ ->
        Mix.shell().error("Usage: mix playmark.debug [--play | --subs | --mem] [<youtube-url>]")
    end
  end

  # --- mem mode: report the BEAM's memory footprint --------------------------

  # A mix task runs in its own BEAM, separate from a live `mix playmark`, so we
  # can't attach to a running TUI and read its heap. Instead we reproduce the
  # app's real workload in-process: the started-app baseline, then the cost of
  # loading a channel exactly as the TUI does (Playmark.Channel.list_videos/2).
  defp mem_mode(nil) do
    shell = Mix.shell()

    shell.info("== BEAM memory: started-app baseline ==")
    shell.info("  (this is the app booted but idle — no channel loaded)\n")

    report_memory(baseline_memory(), shell)

    shell.info(
      "\n  Pass a channel URL to measure the cost of loading its video list:\n" <>
        "    mix playmark.debug --mem <channel-url>"
    )
  end

  defp mem_mode(url) do
    shell = Mix.shell()

    before = baseline_memory()

    shell.info("== BEAM memory: started-app baseline ==\n")
    report_memory(before, shell)

    shell.info("\n== Loading channel (as the TUI does) ==")
    shell.info("  #{url}")

    started = System.monotonic_time(:millisecond)

    case Playmark.Channel.list_videos(url) do
      {:ok, videos} ->
        elapsed = (System.monotonic_time(:millisecond) - started) / 1000
        shell.info("  loaded #{video_count(videos)} in #{fmt(elapsed)}s (cold)\n")

        # enrich_titles fans out a task per video and holds title strings; force
        # a GC so we measure retained working set, not transient garbage. GC
        # *every* process, not just this one — the HTTP pool and async_stream
        # workers left behind each carry their own uncollected heap.
        gc_all()
        after_load = current_memory()

        shell.info("== BEAM memory: after loading the channel ==\n")
        report_memory(after_load, shell)

        shell.info("\n== Delta (loaded − baseline) ==\n")
        report_delta(before, after_load, shell)

        warm_load(url, elapsed, shell)

      {:error, reason} ->
        shell.error("  channel load failed: #{reason}")
    end
  end

  # The first load populated Playmark.Cache with every title. Reload the same
  # channel: yt-dlp still refetches the video *set* (it's never cached), but
  # enrich_titles now serves every title from ETS instead of oEmbed, so the
  # network fan-out disappears. Report the warm timing next to the cold one and
  # the cache's ETS footprint — that's the optimization made concrete.
  defp warm_load(url, cold, shell) do
    # put/2 is a cast; flush it so the warm run is guaranteed to see the entries.
    Playmark.Cache.sync()

    shell.info("\n== Reloading the same channel (warm — titles cached) ==")

    started = System.monotonic_time(:millisecond)

    case Playmark.Channel.list_videos(url) do
      {:ok, videos} ->
        warm = (System.monotonic_time(:millisecond) - started) / 1000
        saved = cold - warm

        shell.info("  loaded #{video_count(videos)} in #{fmt(warm)}s (warm)")
        shell.info("  cold #{fmt(cold)}s → warm #{fmt(warm)}s (#{fmt(saved)}s saved)\n")

        gc_all()
        shell.info("== BEAM memory: cache footprint ==\n")
        shell.info("  ets  #{mb(current_memory().ets)} (includes the title cache)")

      {:error, reason} ->
        shell.error("  warm reload failed: #{reason}")
    end
  end

  # Boot leaves transient garbage on the heap; GC first so the baseline is the
  # retained footprint, not startup churn.
  defp baseline_memory do
    gc_all()
    current_memory()
  end

  # :erlang.garbage_collect/0 collects only the caller. Sweep every live process
  # so the reading reflects retained memory, not garbage sitting in the HTTP
  # pool or async_stream workers spawned during the load.
  defp gc_all do
    Enum.each(Process.list(), &:erlang.garbage_collect/1)
  end

  defp current_memory do
    mem = :erlang.memory()

    %{
      total: mem[:total],
      processes: mem[:processes],
      binary: mem[:binary],
      ets: mem[:ets],
      process_count: :erlang.system_info(:process_count)
    }
  end

  defp report_memory(m, shell) do
    shell.info("  total      #{mb(m.total)}")
    shell.info("  processes  #{mb(m.processes)}")
    shell.info("  binary     #{mb(m.binary)}")
    shell.info("  ets        #{mb(m.ets)}")
    shell.info("  processes  #{m.process_count} (count)")
  end

  defp report_delta(before, aft, shell) do
    shell.info("  total      #{mb_delta(aft.total - before.total)}")
    shell.info("  processes  #{mb_delta(aft.processes - before.processes)}")
    shell.info("  binary     #{mb_delta(aft.binary - before.binary)}")
    shell.info("  ets        #{mb_delta(aft.ets - before.ets)}")
    shell.info("  processes  #{aft.process_count - before.process_count} (count)")
  end

  defp mb(bytes), do: "#{:erlang.float_to_binary(bytes / 1_048_576, decimals: 1)} MB"

  defp mb_delta(bytes) do
    sign = if bytes >= 0, do: "+", else: "−"
    "#{sign}#{:erlang.float_to_binary(abs(bytes) / 1_048_576, decimals: 1)} MB"
  end

  # --- play mode: run the real VLC command with verbose, timestamped logs ----

  defp play_mode(url) do
    shell = Mix.shell()

    shell.info("== Resolving stream(s) with web_safari (as Playmark.Playback does) ==")

    args = [
      "--extractor-args",
      "youtube:player_client=#{@player_client}",
      "-f",
      Playback.format(),
      "-g",
      url
    ]

    case System.cmd("yt-dlp", args, stderr_to_stdout: true) do
      {output, 0} ->
        urls =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&String.starts_with?(&1, "http"))

        case urls do
          [] ->
            shell.error("  no URLs resolved:\n#{output}")

          urls ->
            Enum.each(urls, fn u -> shell.info("  #{classify(u)}: #{String.slice(u, 0, 80)}…") end)

            launch_vlc_verbose(urls, shell)
        end

      {output, code} ->
        shell.error("  yt-dlp failed (exit #{code}): #{String.trim(output)}")
    end
  end

  # --- subs mode: diagnose why captions do or don't appear -------------------

  # The subtle trap this mode was built to expose: the stream client (web_safari)
  # and the caption client (default) are *different*, because web_safari discards
  # caption tracks with no PO token while default's stream URLs 403. So captions
  # must download with the caption client, separately from stream resolution.
  # This mode shows what each client exposes, runs the real download with the
  # caption client, and prints the exact args each player receives.
  defp subs_mode(url) do
    shell = Mix.shell()
    default = Playback.subtitle_default()
    fallback = Playback.subtitle_fallback()

    shell.info("== Caption config ==")
    shell.info("  subtitles?         #{Playback.subtitles?()}")
    shell.info("  subtitle_default   #{inspect(default)} (uploader subs, first choice)")
    shell.info("  subtitle_fallback  #{inspect(fallback)} (uploader subs, second choice)")

    shell.info(
      "  subtitle_translate #{Playback.subtitle_translate()} (accept machine translation)"
    )

    shell.info("  auto fallback      spoken language (auto-generated)")
    shell.info("  stream client      #{@player_client} (fetchable URLs; drops captions)")
    shell.info("  caption client     #{@subtitle_client} (exposes captions)")

    if not Playback.subtitles?() do
      shell.info("\n  Captions are disabled in config; nothing to diagnose.")
    else
      compare_clients(url, [default, fallback], shell)
      show_selection(url, shell)
      probe_download(url, shell)
      show_player_args(url, shell)
    end
  end

  # Ask each client what it exposes. This is the crux: web_safari commonly reports
  # "no subtitles" while default lists the track. Seeing both side by side is what
  # explains captions vanishing on mpv/VLC despite the video having them.
  # `langs` is the configured chain (default + fallback); we flag matches for any.
  defp compare_clients(url, langs, shell) do
    wanted = Enum.reject(langs, &(&1 in [nil, ""]))

    for client <- [@player_client, @subtitle_client] do
      shell.info("\n== Tracks reported by #{client} (--list-subs) ==")

      args = [
        "--extractor-args",
        "youtube:player_client=#{client}",
        "--list-subs",
        "--skip-download",
        url
      ]

      case System.cmd("yt-dlp", args, stderr_to_stdout: true) do
        {output, 0} ->
          shell.info(String.trim_trailing(output))

          matching =
            output
            |> String.split("\n", trim: true)
            |> Enum.filter(fn line ->
              trimmed = String.trim(line)
              Enum.any?(wanted, &String.starts_with?(trimmed, &1))
            end)

          case matching do
            [] ->
              shell.info("  → no track matching #{inspect(wanted)} on this client")

            hits ->
              shell.info(
                "  → matching #{inspect(wanted)}: #{Enum.map_join(hits, ", ", &String.trim/1)}"
              )
          end

        {output, code} ->
          shell.error("  --list-subs failed (exit #{code}): #{String.trim(output)}")
      end
    end
  end

  # Show which tier of the preference chain actually wins, using the same
  # probe + select logic the backends use (Playmark.Player.Captions.select/2).
  defp show_selection(url, shell) do
    shell.info("\n== Track selected by the preference chain ==")

    opts = probe_opts()

    case Playmark.Player.Captions.probe_for_debug(url, opts) do
      {:ok, probe} ->
        spoken = probe["language"]
        shell.info("  spoken language: #{inspect(spoken)}")

        case Playmark.Player.Captions.select(probe, opts) do
          {:manual, key} ->
            shell.info("  → manual (uploader) track #{inspect(key)}")

          {:translated, key} ->
            # A `{target}-{source}` key translates that uploader track; a plain
            # key translates the ASR transcript. Name the source either way —
            # it's the difference between one lossy pass and two. Split only when
            # the suffix names a real manual track, mirroring `auto_kind/2`, so a
            # regional variant like "en-US" isn't read as "en from US".
            manual = probe |> Map.get("subtitles", %{}) |> Map.keys()

            source =
              case String.split(key, "-", parts: 2) do
                [_target, s] -> if s in manual, do: s, else: nil
                _ -> nil
              end

            if source do
              [target | _] = String.split(key, "-", parts: 2)

              shell.info(
                "  → auto-translated track #{inspect(key)}: #{target} " <>
                  "machine-translated from the uploader's #{source} track"
              )
            else
              shell.info(
                "  → auto-translated track #{inspect(key)}: machine-translated " <>
                  "from the auto-generated transcript"
              )
            end

          {:auto, key} ->
            shell.info("  → auto-generated track #{inspect(key)} (spoken language)")

          :none ->
            shell.info("  → nothing matches; plays without captions")
        end

      :error ->
        shell.info("  probe failed (see debug log); can't determine selection")
    end
  end

  # Run the real download the backends run (Playmark.Player.Captions), with the
  # caption client, and report whether a .vtt actually landed. This is the same
  # path the caption-capable mpv and VLC backends use.
  defp probe_download(url, shell) do
    shell.info("\n== Downloading the sidecar (caption client: #{@subtitle_client}) ==")

    case Playmark.Player.Captions.download(url, probe_opts()) do
      nil ->
        shell.info("  no file produced (see debug log). mpv/VLC play without captions.")

      path ->
        size = File.stat!(path).size
        shell.info("  wrote #{path} (#{size} bytes)")
        shell.info("  → mpv and VLC get --sub-file=#{path}")
        Playmark.Player.Captions.cleanup(path)
    end
  end

  # The caption-related opts the backends build, mirrored here for the diagnostics.
  defp probe_opts do
    %{
      subtitle_client: @subtitle_client,
      subtitle_default: Playback.subtitle_default(),
      subtitle_fallback: Playback.subtitle_fallback(),
      subtitle_translate: Playback.subtitle_translate()
    }
  end

  # Print the exact args each backend hands its player. mpv and VLC attach the
  # downloaded sidecar; ffplay deliberately omits it.
  defp show_player_args(url, shell) do
    opts = %{
      format: Playback.format(),
      subtitles?: Playback.subtitles?(),
      subtitle_default: Playback.subtitle_default(),
      subtitle_fallback: Playback.subtitle_fallback(),
      subtitle_translate: Playback.subtitle_translate(),
      player_client: @player_client,
      subtitle_client: @subtitle_client,
      title: "<video-title>",
      author: "<channel-name>"
    }

    sub = "<downloaded-sub>.vtt"

    shell.info("\n== Args each player is launched with (sidecar shown as #{sub}) ==")

    shell.info("  mpv:")
    shell.info(indent(Enum.join(Playmark.Player.Mpv.play_args(url, sub, opts), " \\\n    ")))

    shell.info("\n  vlc:")
    urls = ["<resolved-stream-url>"]
    shell.info(indent(Enum.join(Playmark.Player.Vlc.launch_args(urls, sub, opts), " \\\n    ")))

    shell.info("\n  ffplay (no YouTube caption sidecar):")

    shell.info(
      indent(
        Enum.join(
          Playmark.Player.Ffplay.play_args("<resolved-muxed-stream-url>", opts),
          " \\\n    "
        )
      )
    )

    shell.info(
      "\n  → mpv and VLC attach the downloaded track with --sub-file\n" <>
        "    (mpv --sid=1; VLC shows it by default). If a track downloads but nothing\n" <>
        "    shows, check the .vtt is non-empty and the select flag is present."
    )
  end

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &"    #{&1}")
  end

  # A URL is an HLS playlist (VLC re-fetches segments over time — a segment that
  # later 403s looks like end-of-stream and, with --play-and-exit, quits VLC) or
  # a progressive file (one long-lived connection).
  defp classify(url) do
    cond do
      String.contains?(url, "hls_playlist") or String.contains?(url, ".m3u8") -> "HLS playlist"
      true -> "progressive"
    end
  end

  defp launch_vlc_verbose(urls, shell) do
    vlc_args = ["-vv" | vlc_url_args(urls)]

    shell.info("\n== Launching real VLC command (-vv). Watch the timestamps. ==")
    shell.info("  $ vlc #{Enum.map_join(vlc_args, " ", &redact/1)}")
    shell.info("  (Close VLC yourself; note the elapsed time if it dies on its own.)\n")

    started = System.monotonic_time(:millisecond)

    port =
      Port.open({:spawn_executable, System.find_executable("vlc")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: vlc_args
      ])

    stream_vlc(port, started, shell)
  end

  # Mirror VLC's stream URL layout: one muxed URL, or video plus slave audio.
  defp vlc_url_args([video]),
    do: ["-f", "--no-video-title-show", "--play-and-exit", video]

  defp vlc_url_args([video, audio | _]),
    do: ["-f", "--no-video-title-show", "--play-and-exit", video, "--input-slave=#{audio}"]

  defp stream_vlc(port, started, shell) do
    receive do
      {^port, {:data, data}} ->
        elapsed = (System.monotonic_time(:millisecond) - started) / 1000

        data
        |> String.split("\n", trim: true)
        |> Enum.each(fn line -> IO.puts(:stderr, "[#{fmt(elapsed)}s] #{line}") end)

        stream_vlc(port, started, shell)

      {^port, {:exit_status, status}} ->
        elapsed = (System.monotonic_time(:millisecond) - started) / 1000
        shell.info("\n== VLC exited after #{fmt(elapsed)}s with status #{status} ==")

        if elapsed < 60 do
          shell.info(
            "  Died early. Look above for the last HTTP status / 'access stream error' /\n" <>
              "  'cannot open' line just before exit — that's the cause."
          )
        end
    end
  end

  defp fmt(seconds), do: :erlang.float_to_binary(seconds, decimals: 1)

  # Keep the long signed URLs out of the echoed command line.
  defp redact("http" <> _), do: "<video-url>"
  defp redact("--input-slave=" <> _), do: "--input-slave=<audio-url>"
  defp redact(arg), do: arg

  defp diagnose(url) do
    shell = Mix.shell()

    shell.info("== Executables ==")

    for exe <- ~w(yt-dlp vlc) do
      shell.info("  #{exe}: #{System.find_executable(exe) || "NOT FOUND"}")
    end

    shell.info("\n== Testing yt-dlp player-client strategies ==")
    shell.info("  format: #{Playback.format()}")
    shell.info("  probing each URL as VLC would (ranged GET, VLC User-Agent)\n")

    results = Enum.map(@clients, &test_client(&1, url, shell))

    shell.info("\n== Summary ==")

    Enum.each(results, fn {client, verdict} ->
      shell.info("  #{String.pad_trailing(client, 24)} #{verdict}")
    end)

    case Enum.find(results, fn {_c, v} -> String.starts_with?(v, "OK") end) do
      {client, _} ->
        shell.info("\n  → Working strategy: #{client}")
        shell.info("    I'll wire this into the playback module.")

      nil ->
        shell.info("\n  → No strategy produced fetchable URLs. Paste this output back.")
    end
  end

  defp test_client(client, url, shell) do
    shell.info("-- #{client} --")

    args = client_args(client) ++ ["-f", Playback.format(), "-g", url]
    shell.info("  $ yt-dlp #{Enum.join(args, " ")}")

    case System.cmd("yt-dlp", args, stderr_to_stdout: true) do
      {output, 0} ->
        urls =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&String.starts_with?(&1, "http"))

        case urls do
          [] ->
            shell.info("  no URLs resolved\n")
            {client, "no URLs"}

          urls ->
            statuses = Enum.map(urls, &probe(&1, shell))

            verdict =
              if Enum.all?(statuses, &(&1 in 200..299)),
                do: "OK (#{Enum.join(statuses, ",")})",
                else: "FAIL (#{Enum.join(statuses, ",")})"

            shell.info("  verdict: #{verdict}\n")
            {client, verdict}
        end

      {output, code} ->
        first_error =
          output
          |> String.split("\n", trim: true)
          |> Enum.find(&String.contains?(&1, "ERROR"))

        shell.info("  yt-dlp failed (exit #{code}): #{first_error || "see output"}\n")
        {client, "yt-dlp exit #{code}"}
    end
  end

  defp client_args("default" <> _), do: []

  defp client_args(client),
    do: ["--extractor-args", "youtube:player_client=#{client}"]

  defp video_count(videos) do
    count = length(videos)
    "#{count} #{if count == 1, do: "video", else: "videos"}"
  end

  # Probe a stream URL the way VLC does: a ranged GET with VLC's User-Agent,
  # following redirects. Report the final HTTP status.
  defp probe(url, shell) do
    label = url |> String.slice(0, 70)

    result =
      Req.get(url,
        headers: [{"user-agent", @vlc_user_agent}, {"range", "bytes=0-1"}],
        redirect: true,
        retry: false,
        receive_timeout: 15_000,
        decode_body: false
      )

    case result do
      {:ok, %Req.Response{status: status}} ->
        shell.info("    [#{status}] #{label}...")
        status

      {:error, reason} ->
        shell.info("    [ERR] #{label}... (#{inspect(reason)})")
        :error
    end
  end
end
