defmodule Playmark.Source.LocalFiles do
  @moduledoc """
  Reads the browsable entries in a registered local directory.

  This is the local-filesystem counterpart to `Playmark.Source.Channel`: where Channel
  shells out to `yt-dlp` for a channel's videos, `Playmark.Source.LocalFiles` reads a
  directory's top-level entries and keeps child directories plus files that look
  like playable media. File entries retain the `%{id, title, url}` shape used by
  channel videos, while every entry has a `:kind` discriminator so the TUI can
  open directories instead of trying to play them.

  Only the requested directory's top level is read. Child directory symlinks are
  ignored so browsing cannot follow a cycle or escape the registered tree.

  `delete/2` is the one operation here that is not a read: it is the destructive
  half of the local browser, and it is the reason the containment check below is
  shared rather than inlined into the listing. Deleting needs the same proof the
  reading does — that the path is a real, non-symlinked child of the registered
  root — and a second copy of that proof is a second place for it to rot.
  """

  @media_extensions ~w(.mp4 .mkv .webm .avi .mov .m4v .mpg .mpeg .flv .wmv
                       .mp3 .flac .wav .ogg .opus .m4a .aac .wma)

  @doc """
  Lists child directories and playable media files directly inside `dir`.

  Directories sort first, followed by files, with natural filename ordering in
  each group. Non-media and special files are dropped.
  """
  def list_entries(dir) when is_binary(dir), do: list_entries(dir, dir)

  @doc """
  Lists `dir` while enforcing that each path component below `root` is a real
  directory rather than a symlink.

  The root itself may be a directory symlink because registered roots have
  historically allowed them.
  """
  def list_entries(dir, root) when is_binary(dir) and is_binary(root) do
    case validate_directory(dir, root) do
      :ok -> list_entries_unchecked(dir)
      {:error, reason} -> {:error, "could not read #{dir}: #{reason}"}
    end
  end

  @doc """
  Permanently deletes `path`, a file directly inside the registered tree at `root`.

  Unlinking is irreversible, so the same containment proof the listing applies is
  required here: `Path.dirname(path)` must be a real, non-symlinked directory below
  `root`. That is enough to place `path` — it is checked separately with `lstat`, so
  a directory is refused even if a caller's own guard let one through. A symlink is
  accepted and only the link is removed, leaving its target, which is what `rm`
  does and the only reading that cannot reach outside the tree.
  """
  def delete(path, root) when is_binary(path) and is_binary(root) do
    with :ok <- validate_directory(Path.dirname(path), root),
         :ok <- validate_deletable(path),
         :ok <- rm(path) do
      :ok
    else
      {:error, reason} -> {:error, "could not delete #{path}: #{reason}"}
    end
  end

  defp rm(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, reason} -> {:error, to_string(:file.format_error(reason))}
    end
  end

  defp validate_deletable(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: type}} when type in [:regular, :symlink] -> :ok
      {:ok, _stat} -> {:error, "not a file"}
      {:error, reason} -> {:error, to_string(:file.format_error(reason))}
    end
  end

  defp list_entries_unchecked(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries =
          entries
          |> Enum.map(fn name -> {name, Path.join(dir, name)} end)
          |> Enum.map(&entry/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(fn item -> {kind_order(item.kind), natural_key(item.title)} end)

        {:ok, entries}

      {:error, reason} ->
        {:error, "could not read #{dir}: #{:file.format_error(reason)}"}
    end
  end

  # Containment only — the reasons are verb-free so `list_entries/2` and `delete/2`
  # can each name their own operation in the message they wrap around them.
  defp validate_directory(dir, root) do
    expanded_dir = Path.expand(dir)
    expanded_root = Path.expand(root)
    relative = Path.relative_to(expanded_dir, expanded_root)
    parts = Path.split(relative)

    cond do
      expanded_dir == expanded_root ->
        :ok

      relative == expanded_dir or List.first(parts) == ".." ->
        {:error, "outside registered directory"}

      true ->
        validate_components(expanded_root, parts)
    end
  end

  defp validate_components(root, parts) do
    Enum.reduce_while(parts, root, fn part, parent ->
      path = Path.join(parent, part)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} ->
          {:cont, path}

        {:ok, _stat} ->
          {:halt, {:error, "not a browsable directory"}}

        {:error, reason} ->
          {:halt, {:error, to_string(:file.format_error(reason))}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      _path -> :ok
    end
  end

  defp entry({name, path}) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        %{kind: :directory, id: path, title: name, path: path}

      {:ok, %File.Stat{type: :regular}} ->
        file_entry(name, path)

      {:ok, %File.Stat{type: :symlink}} ->
        if File.regular?(path), do: file_entry(name, path)

      _ ->
        nil
    end
  end

  defp file_entry(name, path) do
    if media?(name), do: %{kind: :file, id: path, title: name, url: path}
  end

  defp kind_order(:directory), do: 0
  defp kind_order(:file), do: 1

  defp media?(name), do: String.downcase(Path.extname(name)) in @media_extensions

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
