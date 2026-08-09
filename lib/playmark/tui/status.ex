defmodule Playmark.TUI.Status do
  @moduledoc """
  Pure text builders for the footer status line.

  Every `{:info, …}` / `{:error, …}` status the TUI sets is a short sentence
  built the same few ways: a pluralized count of what a fetch returned, or a
  readable rendering of why an add failed. The state each caller writes differs;
  the phrasing does not, which is what lives here.

  `count_with_label/3` in particular had drifted into three near-copies (the
  runtime shell, the queue modal, the history modal) that were not identical —
  one had lost its optional-plural default. Both counters are shared from here
  now, so a new caller can't fork a fourth.

  Nothing here touches TUI state, spawns a task, or does IO. These take plain
  lists, integers, and changesets and return strings.
  """

  @doc """
  A count with its label pluralized: `"1 video"`, `"3 videos"`.

  `plural` overrides the default `singular <> "s"` for labels that don't take a
  bare `s` (`"history entry"` → `"history entries"`).
  """
  def count_with_label(items, singular, plural \\ nil) do
    count = length(items)
    label = if count == 1, do: singular, else: plural || singular <> "s"
    "#{count} #{label}"
  end

  @doc """
  `count_with_label/3` for a count that was already computed rather than a list
  to measure — used where one collection yields two tallies (folders and files).
  """
  def count_with_number(count, singular) do
    label = if count == 1, do: singular, else: singular <> "s"
    "#{count} #{label}"
  end

  @doc """
  Why an add failed, in words a user can act on.

  A duplicate (the unique index on `:url` / `:path`) is the common, expected add
  failure — the raw "url has already been taken" reads poorly, so we map it to a
  per-target message. `target` is `:bookmark` / `:subscription` / `:local` /
  `:playlist`. Any other changeset error keeps the generic field-by-field text; a
  plain reason (e.g. a yt-dlp/oEmbed string) passes through unchanged.
  """
  def add_error(%Ecto.Changeset{} = changeset, target) do
    if duplicate?(changeset), do: duplicate_message(target), else: changeset_errors(changeset)
  end

  def add_error(reason, _target), do: to_string(reason)

  # True when the changeset failed only because the URL/path is already taken.
  defp duplicate?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} -> opts[:constraint] == :unique end)
  end

  defp duplicate_message(:subscription), do: "Already subscribed to this channel"
  defp duplicate_message(:local), do: "Directory already registered"
  defp duplicate_message(:playlist), do: "Playlist already saved"
  defp duplicate_message(_bookmark), do: "Already bookmarked"

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end
end
