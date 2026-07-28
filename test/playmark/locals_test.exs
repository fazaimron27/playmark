defmodule Playmark.LocalsTest do
  use Playmark.DataCase, async: false

  alias Playmark.{Local, Locals}

  setup do
    dir =
      Path.join(System.tmp_dir!(), "playmark_locals_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "add_local/1" do
    test "registers an existing directory, deriving its name", %{dir: dir} do
      assert {:ok, local} = Locals.add_local(dir)
      assert local.path == dir
      assert local.name == Path.basename(dir)
    end

    test "expands the path before storing it", %{dir: dir} do
      assert {:ok, local} = Locals.add_local(Path.join(dir, "."))
      assert local.path == dir
    end

    test "rejects a path that is not a directory" do
      assert {:error, reason} = Locals.add_local("/nonexistent/playmark/path")
      assert reason =~ "not a directory"
    end

    test "rejects a duplicate path", %{dir: dir} do
      assert {:ok, _} = Locals.add_local(dir)
      assert {:error, changeset} = Locals.add_local(dir)
      refute changeset.valid?
    end
  end

  test "lists locals newest first" do
    older = insert_local("/tmp/a", "A", ~N[2026-01-01 00:00:00])
    newer = insert_local("/tmp/b", "B", ~N[2026-02-01 00:00:00])
    assert Enum.map(Locals.list_locals(), & &1.id) == [newer.id, older.id]
  end

  test "deletes a local" do
    local = insert_local("/tmp/doomed", "Doomed")
    assert {:ok, _} = Locals.delete_local(local)
    assert Locals.list_locals() == []
  end

  test "keeps a registration after its directory disappears", %{dir: dir} do
    assert {:ok, local} = Locals.add_local(dir)
    File.rm_rf!(dir)

    assert [%Local{id: id, path: ^dir}] = Locals.list_locals()
    assert id == local.id
  end

  defp insert_local(path, name, inserted_at \\ ~N[2026-01-15 00:00:00]) do
    Repo.insert!(%Local{
      path: path,
      name: name,
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
  end
end
