defmodule Playmark.Local do
  @moduledoc """
  Reads the media files in a registered local directory.

  This is the local-filesystem counterpart to `Playmark.Channel`: where Channel
  shells out to `yt-dlp` for a channel's videos, `Playmark.Local` reads a
  directory's top-level entries and keeps the ones that look like playable media.
  It returns the same map shape a channel video has — `%{id, title, url}` — so a
  local file flows into the TUI's shared `:videos` mode unchanged. Here `url` is
  the absolute file path (what the player is handed) and `title` is the filename.

  Only the directory's top level is read — subdirectories are ignored — so the
  listing is predictable and fast even on large or network-mounted trees.
  """

  # Media extensions we consider playable. Kept at the use site (this list) per
  # the project's "default lives where it's read" convention; there's no user
  # setting for it. Lowercased for a case-insensitive match.
  @media_extensions ~w(.mp4 .mkv .webm .avi .mov .m4v .mpg .mpeg .flv .wmv
                       .mp3 .flac .wav .ogg .opus .m4a .aac .wma)

  @doc """
  Lists the playable media files directly inside `dir`, in natural filename order.

  Sorting is "natural" — embedded numbers compare as numbers, so `file2` sorts
  before `file10` (a plain lexical sort would reverse them), matching how numbered
  episodes/tracks are expected to play. See `natural_key/1`.

  Returns `{:ok, [%{id: String.t(), title: String.t(), url: String.t()}]}` or
  `{:error, reason}`. `id` and `url` are the file's absolute path; `title` is its
  filename. Subdirectories and non-media files are dropped.
  """
  def list_files(dir) when is_binary(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        files =
          entries
          |> Enum.sort_by(&natural_key/1)
          |> Enum.map(fn name -> {name, Path.join(dir, name)} end)
          |> Enum.filter(fn {name, path} -> media?(name) and File.regular?(path) end)
          |> Enum.map(fn {name, path} -> %{id: path, title: name, url: path} end)

        {:ok, files}

      {:error, reason} ->
        {:error, "could not read #{dir}: #{:file.format_error(reason)}"}
    end
  end

  defp media?(name) do
    String.downcase(Path.extname(name)) in @media_extensions
  end

  # A sort key that orders embedded numbers by value, not lexically, so
  # "ep2" sorts before "ep10" (plain string sort puts "ep10" first). We split the
  # (downcased) name into digit and non-digit runs, turning each digit run into an
  # integer; comparing the resulting lists compares numbers as numbers and text as
  # text. Integers sort before binaries in Erlang term order, so a numeric run and
  # a text run never compare against each other at the same position for names that
  # share a structure — the common case for episode/track numbering.
  defp natural_key(name) do
    name
    |> String.downcase()
    |> then(&Regex.scan(~r/\d+|\D+/, &1))
    |> Enum.map(fn [chunk] ->
      case Integer.parse(chunk) do
        {int, ""} -> int
        _ -> chunk
      end
    end)
  end
end
