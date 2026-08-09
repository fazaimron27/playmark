defmodule Playmark.TUI.HelpActions do
  @moduledoc """
  The keybinding help overlay.

  Like the queue and history modals it opens over a browse mode and restores it
  on close, but it is otherwise the simplest overlay in the TUI: it spawns no
  task, reads nothing but the mode it was opened from, and has no list to
  navigate. The content it displays is hand-authored in
  `Playmark.TUI.View.help_body/0` and kept in lockstep with the key handlers by
  hand — nothing here generates it.
  """

  @doc """
  Opens the help overlay, remembering the mode to restore on close.

  `?` is bound from every browse mode except `:help` itself, so a second `?`
  closes rather than reopens.
  """
  def open_help(state) do
    %{state | mode: :help, help_return: state.mode}
  end

  @doc """
  `q` quits; `?` and Esc close the overlay back to where it was opened. Every
  other key is a no-op — the overlay is purely informational.
  """
  def handle_help_key("q", state), do: {:stop, state}

  def handle_help_key(code, state) when code in ["esc", "?"] do
    {:noreply, %{state | mode: state.help_return}}
  end

  def handle_help_key(_code, state), do: {:noreply, state}
end
