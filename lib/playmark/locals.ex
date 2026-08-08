defmodule Playmark.Locals do
  @moduledoc """
  Context for registering local media directories.

  A local stores only the directory path and its basename. Files are read live
  through `Playmark.Source.LocalFiles` whenever the directory is opened.
  """

  import Ecto.Query, only: [from: 2]

  alias Playmark.{Local, Repo}

  @doc "Lists all registered local directories, newest first."
  def list_locals do
    Repo.all(from(local in Local, order_by: [desc: local.inserted_at]))
  end

  @doc "Registers an existing local directory."
  def add_local(path) when is_binary(path) do
    path = path |> String.trim() |> Path.expand()

    if File.dir?(path) do
      %Local{}
      |> Local.changeset(%{path: path, name: Path.basename(path)})
      |> Repo.insert()
    else
      {:error, "not a directory: #{path}"}
    end
  end

  @doc "Removes a local-directory registration."
  def delete_local(%Local{} = local), do: Repo.delete(local)
end
