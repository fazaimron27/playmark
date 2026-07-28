defmodule Mix.Tasks.Playmark do
  @moduledoc """
  Launches the playmark terminal UI.

      mix playmark

  Loads user configuration, verifies that `yt-dlp` and the configured media
  player (`vlc` by default, or `mpv`/`ffplay`) are installed, then opens the TUI.
  Use `j`/`k` to navigate, `a` to add a bookmark, `Enter` to play the selected
  video, and `q` to quit.
  """
  @shortdoc "Launch the playmark terminal UI"

  use Mix.Task

  @impl true
  def run(_argv) do
    {:ok, _apps} = Application.ensure_all_started(:playmark)

    case Playmark.SystemCheck.verify() do
      :ok ->
        quiet_console(fn -> launch_tui() end)

      {:error, missing} ->
        Playmark.SystemCheck.log_missing(missing)
        exit({:shutdown, 1})
    end
  end

  defp launch_tui do
    {:ok, pid} = Playmark.TUI.start_link(name: nil)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  # The TUI owns the terminal, so any log line written to stdout/stderr would
  # corrupt rendering. Detach the console log handler for the session (logs
  # still reach any file handler) and restore it afterwards.
  defp quiet_console(fun) do
    config = safe_handler_config(:default)
    :ok = remove_default_handler()

    try do
      fun.()
    after
      restore_default_handler(config)
    end
  end

  defp safe_handler_config(id) do
    case :logger.get_handler_config(id) do
      {:ok, config} -> config
      _ -> nil
    end
  end

  defp remove_default_handler do
    case :logger.remove_handler(:default) do
      :ok -> :ok
      {:error, {:not_found, _}} -> :ok
      other -> other
    end
  end

  defp restore_default_handler(nil), do: :ok

  defp restore_default_handler(%{module: module} = config) do
    _ = :logger.add_handler(:default, module, config)
    :ok
  end
end
