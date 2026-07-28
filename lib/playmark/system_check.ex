defmodule Playmark.SystemCheck do
  @moduledoc """
  Verifies that the external programs playmark depends on are installed.

  Always requires `yt-dlp`, plus whichever media player is configured (`vlc` by
  default, or `mpv`/`ffplay`). We don't require every player, only the one that
  will actually be used.
  """

  require Logger

  alias Playmark.Playback

  @install_hints %{
    "yt-dlp" => "https://github.com/yt-dlp/yt-dlp#installation",
    "mpv" => "https://mpv.io/installation/",
    "vlc" => "https://www.videolan.org/vlc/",
    "ffplay" => "https://ffmpeg.org/download.html"
  }

  @doc """
  Returns `:ok` if every required executable is on the PATH, otherwise
  `{:error, missing}` where `missing` is a list of program names.
  """
  def verify do
    missing = Enum.reject(required(), &System.find_executable/1)

    case missing do
      [] -> :ok
      _ -> {:error, missing}
    end
  end

  @doc """
  The executables required for the current configuration: `yt-dlp` plus the
  configured player.
  """
  def required do
    ["yt-dlp", Playback.executable()]
  end

  @doc """
  Logs a helpful message describing the missing executables.
  """
  def log_missing(missing) do
    Logger.error("""
    playmark requires the following programs, but they were not found on your PATH:

    #{Enum.map_join(missing, "\n", &"  - #{&1}: #{@install_hints[&1]}")}

    (The media player is set by `config :playmark, :player` — #{inspect(Playback.player())}.)
    """)
  end
end
