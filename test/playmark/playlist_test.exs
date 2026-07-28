defmodule Playmark.PlaylistTest do
  use ExUnit.Case, async: true

  alias Playmark.Playlist

  describe "changeset/2" do
    test "accepts URL, title, and channel" do
      changeset =
        Playlist.changeset(%Playlist{}, %{
          url: "https://www.youtube.com/playlist?list=PL123",
          title: "Lessons",
          channel: "Teacher"
        })

      assert changeset.valid?
    end

    test "requires URL and title but allows a missing channel" do
      refute Playlist.changeset(%Playlist{}, %{}).valid?
      assert Playlist.changeset(%Playlist{}, %{url: "u", title: "t"}).valid?
    end
  end
end
