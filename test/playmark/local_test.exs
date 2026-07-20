defmodule Playmark.LocalTest do
  use ExUnit.Case, async: true

  alias Playmark.Local

  setup do
    dir =
      Path.join(System.tmp_dir!(), "playmark_local_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "list_files/1" do
    test "returns media files sorted by name, with the file-video map shape", %{dir: dir} do
      touch(dir, "b.mp4")
      touch(dir, "a.mkv")

      assert {:ok, [first, second]} = Local.list_files(dir)
      assert first.title == "a.mkv"
      assert first.id == Path.join(dir, "a.mkv")
      assert first.url == Path.join(dir, "a.mkv")
      assert second.title == "b.mp4"
    end

    test "keeps audio and video extensions, case-insensitively", %{dir: dir} do
      touch(dir, "song.MP3")
      touch(dir, "clip.WebM")

      assert {:ok, files} = Local.list_files(dir)
      assert Enum.map(files, & &1.title) |> Enum.sort() == ["clip.WebM", "song.MP3"]
    end

    test "drops non-media files", %{dir: dir} do
      touch(dir, "notes.txt")
      touch(dir, "cover.jpg")
      touch(dir, "movie.mp4")

      assert {:ok, [file]} = Local.list_files(dir)
      assert file.title == "movie.mp4"
    end

    test "ignores subdirectories, even media-named ones", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "season.mp4"))
      touch(dir, "episode.mp4")

      assert {:ok, [file]} = Local.list_files(dir)
      assert file.title == "episode.mp4"
    end

    test "returns an empty list for a directory with no media", %{dir: dir} do
      touch(dir, "readme.md")

      assert {:ok, []} = Local.list_files(dir)
    end

    test "returns an error for a missing directory" do
      assert {:error, reason} = Local.list_files("/nonexistent/playmark/dir")
      assert reason =~ "could not read"
    end
  end

  defp touch(dir, name), do: File.write!(Path.join(dir, name), "")
end
