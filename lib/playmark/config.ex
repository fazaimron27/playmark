defmodule Playmark.Config do
  @moduledoc """
  Loads user settings from a dotenv-style file at boot.

  playmark has no API keys or secrets, but a few settings are worth letting a user
  change without editing Elixir source: the media player, the playback quality
  cap, and the fetch limits/timeouts. Those live in a plain `key = value` file at
  `~/.config/playmark/config.env` — the same directory as the database
  (`Playmark.Application.data_dir/0`), which is where a single-user local app's
  state belongs (not the checked-out source tree).

  `load/0` runs once from `Playmark.Application.start/2`, parses the file if it
  exists, coerces each recognized key to its type, and writes it into the
  `:playmark` application env with `Application.put_env/3`. The consuming modules
  (`Playmark.Playback`, `Playmark.Channel`, `Playmark.Search`) read those keys via
  `Application.get_env/3`, each supplying the built-in default as the fallback —
  so a missing file, a missing key, or an invalid value all resolve to the same
  behavior the app had before any config existed.

  ## File format

      # ~/.config/playmark/config.env — comments and blank lines are ignored
      player = vlc              # :mpv (default) or :vlc
      max_height = 1080         # max video height for playback
      subtitles = true          # show captions (default true)
      subtitle_default = en     # first-choice caption language (default en)
      subtitle_fallback = id    # second-choice language (optional, no default)
      search_limit = 20         # results per YouTube search
      channel_limit = 30        # videos fetched per channel open
      oembed_timeout_ms = 4000  # per-title oEmbed lookup timeout
      oembed_concurrency = 10   # parallel oEmbed lookups
      socket_timeout = 30       # yt-dlp per-socket timeout, seconds

  Whitespace around keys and values is trimmed. Unknown keys are ignored (with a
  warning) so a typo can't crash boot. An unparseable value for a known key is
  dropped (with a warning) and the built-in default stands.

  Warnings are logged during application start — before `Mix.Tasks.Playmark`
  detaches the console log handler for the TUI session — so they're visible.
  """

  require Logger

  # Recognized keys mapped to {app-env key, coercion}. The coercion returns
  # {:ok, value} or :error; :error keeps the built-in default (read at the use
  # site), so the map deliberately carries no defaults of its own.
  @keys %{
    "player" => {:player, :player},
    "max_height" => {:max_height, :pos_integer},
    "subtitles" => {:subtitles, :boolean},
    "subtitle_default" => {:subtitle_default, :string},
    "subtitle_fallback" => {:subtitle_fallback, :string},
    "search_limit" => {:search_limit, :pos_integer},
    "channel_limit" => {:channel_limit, :pos_integer},
    "oembed_timeout_ms" => {:oembed_timeout_ms, :pos_integer},
    "oembed_concurrency" => {:oembed_concurrency, :pos_integer},
    "socket_timeout" => {:socket_timeout, :pos_integer}
  }

  @doc """
  Absolute path to the user config file (`~/.config/playmark/config.env`).

  Honors an explicit `:config_path` in the `:playmark` app env (used by tests so
  the suite reads a throwaway file instead of the user's real config); otherwise
  defaults to `config.env` in `Playmark.Application.data_dir/0`.
  """
  def path do
    case Application.get_env(:playmark, :config_path) do
      p when is_binary(p) and p != "" -> p
      _ -> Path.join(Playmark.Application.data_dir(), "config.env")
    end
  end

  @doc """
  Reads `path/0` (if present) and applies each recognized setting to the
  `:playmark` application env. A missing file is a no-op. Always returns `:ok`.
  """
  def load do
    case File.read(path()) do
      {:ok, contents} -> apply_settings(parse(contents))
      {:error, :enoent} -> :ok
      {:error, reason} -> Logger.warning("playmark: could not read #{path()}: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Parses dotenv-style `key = value` text into a `%{key => raw_value}` map.

  Blank lines and `#` comment lines are skipped. A trailing inline `# comment`
  after a value is stripped. Keys and values are trimmed. Lines without an `=`
  are ignored. Later duplicate keys win.
  """
  def parse(contents) do
    contents
    |> String.split("\n")
    |> Enum.map(&strip_comment/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
        _ -> acc
      end
    end)
  end

  # --- internal ------------------------------------------------------------

  defp apply_settings(raw) do
    Enum.each(raw, fn {key, value} ->
      case Map.fetch(@keys, key) do
        {:ok, {env_key, type}} -> apply_setting(key, env_key, type, value)
        :error -> Logger.warning("playmark: ignoring unknown config key #{inspect(key)}")
      end
    end)
  end

  defp apply_setting(key, env_key, type, value) do
    case coerce(type, value) do
      {:ok, coerced} ->
        Application.put_env(:playmark, env_key, coerced)

      :error ->
        Logger.warning("playmark: invalid value #{inspect(value)} for #{key}; using default")
    end
  end

  defp coerce(:player, "mpv"), do: {:ok, :mpv}
  defp coerce(:player, "vlc"), do: {:ok, :vlc}
  defp coerce(:player, _), do: :error

  defp coerce(:boolean, value) when value in ~w(true yes on 1), do: {:ok, true}
  defp coerce(:boolean, value) when value in ~w(false no off 0), do: {:ok, false}
  defp coerce(:boolean, _), do: :error

  # A subtitle language code is a free-form string; reject only the empty value.
  defp coerce(:string, ""), do: :error
  defp coerce(:string, value), do: {:ok, value}

  defp coerce(:pos_integer, value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  # Drop a trailing inline comment. A leading '#' (whole-line comment) is left as
  # an empty string after the split, which the blank-line reject then removes.
  defp strip_comment(line) do
    line |> String.split("#", parts: 2) |> hd()
  end
end
