defmodule Playmark.DataCase do
  @moduledoc """
  Test case for tests that touch the database.

  This is a single-user local app on SQLite, so rather than the SQL sandbox
  (which fights SQLite's single-writer model), each test starts from an empty
  `bookmarks` table. Tests using this case must not be `async: true`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Playmark.Repo
      import Ecto.Query
    end
  end

  setup do
    Playmark.Repo.delete_all(Playmark.Bookmarks.Bookmark)
    Playmark.Repo.delete_all(Playmark.Subscriptions.Subscription)
    Playmark.Repo.delete_all(Playmark.Locals.Local)
    Playmark.Repo.delete_all(Playmark.Playlists.Playlist)
    Playmark.Repo.delete_all(Playmark.Queue.Item)
    Playmark.Repo.delete_all(Playmark.History.Item)
    :ok
  end
end
