defmodule Playmark.LocalFilesTest do
  use ExUnit.Case, async: true

  alias Playmark.LocalFiles

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "playmark_local_files_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "list_entries/1" do
    test "returns typed media files sorted by name", %{dir: dir} do
      touch(dir, "b.mp4")
      touch(dir, "a.mkv")

      assert {:ok, [first, second]} = LocalFiles.list_entries(dir)
      assert first.kind == :file
      assert first.title == "a.mkv"
      assert first.id == Path.join(dir, "a.mkv")
      assert first.url == Path.join(dir, "a.mkv")
      assert second.title == "b.mp4"
    end

    test "sorts numbered files naturally, not lexically", %{dir: dir} do
      for name <- ["ep1.mp4", "ep2.mp4", "ep10.mp4", "ep20.mp4"], do: touch(dir, name)

      assert {:ok, files} = LocalFiles.list_entries(dir)
      assert Enum.map(files, & &1.title) == ["ep1.mp4", "ep2.mp4", "ep10.mp4", "ep20.mp4"]
    end

    test "keeps audio and video extensions, case-insensitively", %{dir: dir} do
      touch(dir, "song.MP3")
      touch(dir, "clip.WebM")

      assert {:ok, files} = LocalFiles.list_entries(dir)
      assert Enum.map(files, & &1.title) |> Enum.sort() == ["clip.WebM", "song.MP3"]
    end

    test "drops non-media files", %{dir: dir} do
      touch(dir, "notes.txt")
      touch(dir, "cover.jpg")
      touch(dir, "movie.mp4")

      assert {:ok, [file]} = LocalFiles.list_entries(dir)
      assert file.title == "movie.mp4"
    end

    test "returns directories before files and sorts both groups naturally", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "season10"))
      File.mkdir_p!(Path.join(dir, "season2"))
      File.mkdir_p!(Path.join(dir, "bonus.mp4"))
      touch(dir, "episode10.mp4")
      touch(dir, "episode2.mp4")

      assert {:ok, entries} = LocalFiles.list_entries(dir)

      assert Enum.map(entries, &{&1.kind, &1.title}) == [
               {:directory, "bonus.mp4"},
               {:directory, "season2"},
               {:directory, "season10"},
               {:file, "episode2.mp4"},
               {:file, "episode10.mp4"}
             ]

      assert hd(entries).path == Path.join(dir, "bonus.mp4")
      refute Map.has_key?(hd(entries), :url)
    end

    test "lists one level at a time", %{dir: dir} do
      child = Path.join(dir, "season")
      File.mkdir_p!(child)
      touch(child, "nested.mp4")
      touch(dir, "episode.mp4")

      assert {:ok, entries} = LocalFiles.list_entries(dir)
      assert Enum.map(entries, & &1.title) == ["season", "episode.mp4"]

      assert {:ok, [nested]} = LocalFiles.list_entries(child)
      assert nested.title == "nested.mp4"
    end

    test "returns an empty list for a directory with no media", %{dir: dir} do
      touch(dir, "readme.md")
      assert {:ok, []} = LocalFiles.list_entries(dir)
    end

    test "omits directory symlinks but keeps media file symlinks", %{dir: dir} do
      target_dir = Path.join(dir, "target")
      File.mkdir_p!(target_dir)
      touch(dir, "target.mp4")
      File.ln_s!(target_dir, Path.join(dir, "linked-dir"))
      File.ln_s!(Path.join(dir, "target.mp4"), Path.join(dir, "linked.mp4"))

      assert {:ok, entries} = LocalFiles.list_entries(dir)
      assert Enum.map(entries, & &1.title) == ["target", "linked.mp4", "target.mp4"]
    end

    test "rejects a child replaced by a directory symlink", %{dir: dir} do
      outside =
        Path.join(
          System.tmp_dir!(),
          "playmark_local_files_outside_#{System.unique_integer([:positive])}"
        )

      child = Path.join(dir, "child")
      File.mkdir_p!(outside)
      File.mkdir_p!(child)
      on_exit(fn -> File.rm_rf!(outside) end)

      assert {:ok, [%{kind: :directory, path: ^child}]} = LocalFiles.list_entries(dir)

      File.rm_rf!(child)
      File.ln_s!(outside, child)

      assert {:error, reason} = LocalFiles.list_entries(child, dir)
      assert reason =~ "not a browsable directory"
    end

    test "rejects paths outside the registered root", %{dir: dir} do
      assert {:error, reason} = LocalFiles.list_entries(System.tmp_dir!(), dir)
      assert reason =~ "outside registered directory"
    end

    test "returns an error for a missing directory" do
      assert {:error, reason} = LocalFiles.list_entries("/nonexistent/playmark/dir")
      assert reason =~ "could not read"
    end
  end

  defp touch(dir, name), do: File.write!(Path.join(dir, name), "")
end
