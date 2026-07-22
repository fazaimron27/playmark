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
        %Playmark.HistoryItem{}
        |> Playmark.HistoryItem.changeset(%{
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
