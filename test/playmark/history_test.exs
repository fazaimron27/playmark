defmodule Playmark.HistoryTest do
  use Playmark.DataCase, async: false

  alias Playmark.History

  defp attrs(overrides \\ %{}) do
    Map.merge(%{title: "T", url: "https://y/1", local: false}, overrides)
  end

  describe "record/1" do
    test "inserts a play with played_at set and stores local/author" do
      {:ok, item} =
        History.record(attrs(%{local: true, author: "Some Channel", url: "/vids/clip.mp4"}))

      assert item.local == true
      assert item.author == "Some Channel"
      assert %DateTime{} = item.played_at
    end

    test "rewatching a URL upserts — bumps played_at and refreshes title/author, no dup row" do
      {:ok, first} = History.record(attrs(%{title: "Old", author: "Old Chan"}))
      # A later played_at so the update is observable (truncated to the second).
      later = DateTime.add(first.played_at, 60, :second)

      {:ok, second} =
        %Playmark.History.Item{}
        |> Playmark.History.Item.changeset(%{
          "title" => "New",
          "url" => "https://y/1",
          "author" => "New Chan",
          "played_at" => later
        })
        |> Playmark.Repo.insert(
          on_conflict: {:replace, [:title, :author, :played_at, :updated_at]},
          conflict_target: :url
        )

      assert second.id == first.id
      assert length(History.list_items()) == 1
      [only] = History.list_items()
      assert only.title == "New"
      assert only.author == "New Chan"
      assert DateTime.compare(only.played_at, first.played_at) == :gt
    end

    test "rejects an item missing a required field" do
      assert {:error, changeset} = History.record(%{title: "no url"})
      refute changeset.valid?
    end

    test "upsert preserves an existing resume checkpoint" do
      {:ok, first} = History.record(attrs(%{title: "Old"}))
      {:ok, _} = History.save_checkpoint(first.url, 12_000, 60_000)

      old_played_at = DateTime.add(first.played_at, -60, :second)

      first
      |> Ecto.Changeset.change(played_at: old_played_at)
      |> Playmark.Repo.update!()

      {:ok, _} = History.record(attrs(%{title: "New"}))

      [item] = History.list_items()
      assert item.title == "New"
      assert DateTime.compare(item.played_at, old_played_at) == :gt
      assert item.resume_position_ms == 12_000
      assert item.duration_ms == 60_000
    end
  end

  describe "resume checkpoints" do
    test "lookup returns nil when the URL or checkpoint is absent" do
      assert History.get_checkpoint("missing") == nil

      {:ok, item} = History.record(attrs())
      assert History.get_checkpoint(item.url) == nil
    end

    test "saves and updates a checkpoint by URL" do
      {:ok, item} = History.record(attrs())

      assert {:ok, saved} = History.save_checkpoint(item.url, 1_000, 10_000)
      assert saved.resume_position_ms == 1_000
      assert saved.duration_ms == 10_000

      assert History.get_checkpoint(item.url) == %{
               resume_position_ms: 1_000,
               duration_ms: 10_000
             }

      assert {:ok, updated} = History.save_checkpoint(item.url, 2_500, 12_000)
      assert updated.id == item.id

      assert History.get_checkpoint(item.url) == %{
               resume_position_ms: 2_500,
               duration_ms: 12_000
             }

      assert length(History.list_items()) == 1
    end

    test "returns not found when saving for a URL outside history" do
      assert History.save_checkpoint("missing", 1_000, 10_000) == {:error, :not_found}
    end

    test "clears a checkpoint and is a no-op for an absent URL" do
      {:ok, item} = History.record(attrs())
      {:ok, _} = History.save_checkpoint(item.url, 1_000, 10_000)

      assert :ok = History.clear_checkpoint(item.url)
      assert History.get_checkpoint(item.url) == nil

      [cleared] = History.list_items()
      assert cleared.resume_position_ms == nil
      assert cleared.duration_ms == nil
      assert :ok = History.clear_checkpoint("missing")
    end

    test "rejects negative checkpoint values without replacing the saved checkpoint" do
      {:ok, item} = History.record(attrs())
      {:ok, _} = History.save_checkpoint(item.url, 1_000, 10_000)

      assert {:error, position_changeset} = History.save_checkpoint(item.url, -1, 10_000)

      assert {"must be greater than or equal to %{number}", _} =
               position_changeset.errors[:resume_position_ms]

      assert {:error, duration_changeset} = History.save_checkpoint(item.url, 1_000, -1)

      assert {"must be greater than or equal to %{number}", _} =
               duration_changeset.errors[:duration_ms]

      assert {:error, incomplete_changeset} = History.save_checkpoint(item.url, nil, 10_000)
      assert {"can't be blank", _} = incomplete_changeset.errors[:resume_position_ms]

      assert History.get_checkpoint(item.url) == %{
               resume_position_ms: 1_000,
               duration_ms: 10_000
             }
    end

    test "saving, updating, and clearing do not change played_at" do
      {:ok, item} = History.record(attrs())
      played_at = DateTime.add(item.played_at, -120, :second)

      item
      |> Ecto.Changeset.change(played_at: played_at)
      |> Playmark.Repo.update!()

      assert {:ok, saved} = History.save_checkpoint(item.url, 1_000, 10_000)
      assert saved.played_at == played_at

      assert {:ok, updated} = History.save_checkpoint(item.url, 2_000, 10_000)
      assert updated.played_at == played_at

      assert :ok = History.clear_checkpoint(item.url)
      assert Playmark.Repo.get!(Playmark.History.Item, item.id).played_at == played_at
    end
  end

  describe "list_items/0" do
    test "orders most recently played first" do
      {:ok, a} = History.record(attrs(%{title: "A", url: "u-a"}))
      # Force distinct, increasing played_at values regardless of clock resolution.
      bump = fn item, secs ->
        item
        |> Ecto.Changeset.change(played_at: DateTime.add(item.played_at, secs, :second))
        |> Playmark.Repo.update!()
      end

      {:ok, b} = History.record(attrs(%{title: "B", url: "u-b"}))
      {:ok, c} = History.record(attrs(%{title: "C", url: "u-c"}))

      bump.(a, 0)
      bump.(b, 10)
      bump.(c, 20)

      assert Enum.map(History.list_items(), & &1.title) == ["C", "B", "A"]
    end
  end

  describe "remove/1 and clear/0" do
    test "remove deletes one item and leaves the rest" do
      {:ok, a} = History.record(attrs(%{title: "A", url: "u-a"}))
      {:ok, _b} = History.record(attrs(%{title: "B", url: "u-b"}))

      assert {:ok, _} = History.remove(a)
      assert Enum.map(History.list_items(), & &1.title) == ["B"]
    end

    test "clear empties the history" do
      {:ok, _} = History.record(attrs())
      {:ok, _} = History.record(attrs(%{url: "u-2"}))

      assert :ok = History.clear()
      assert History.list_items() == []
    end
  end
end
