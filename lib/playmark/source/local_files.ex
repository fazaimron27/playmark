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
    with :ok <- validate_directory(dir, root) do
      list_entries_unchecked(dir)
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

  defp validate_directory(dir, root) do
    expanded_dir = Path.expand(dir)
    expanded_root = Path.expand(root)
    relative = Path.relative_to(expanded_dir, expanded_root)
    parts = Path.split(relative)

    cond do
      expanded_dir == expanded_root ->
        :ok

      relative == expanded_dir or List.first(parts) == ".." ->
        {:error, "could not read #{dir}: outside registered directory"}

      true ->
        validate_components(expanded_root, parts, dir)
    end
  end

  defp validate_components(root, parts, requested) do
    Enum.reduce_while(parts, root, fn part, parent ->
      path = Path.join(parent, part)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} ->
          {:cont, path}

        {:ok, _stat} ->
          {:halt, {:error, "could not read #{requested}: not a browsable directory"}}

        {:error, reason} ->
          {:halt, {:error, "could not read #{requested}: #{:file.format_error(reason)}"}}
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
