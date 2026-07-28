defmodule Playmark.QueueTest do
  use Playmark.DataCase, async: false

  alias Playmark.Queue

  defp attrs(overrides \\ %{}) do
    Map.merge(%{title: "T", url: "https://y/1", local: false}, overrides)
  end

  describe "enqueue/1" do
    test "appends items at the tail in insertion order" do
      {:ok, a} = Queue.enqueue(attrs(%{title: "A", url: "u-a"}))
      {:ok, b} = Queue.enqueue(attrs(%{title: "B", url: "u-b"}))
      {:ok, c} = Queue.enqueue(attrs(%{title: "C", url: "u-c"}))

      assert a.position < b.position
      assert b.position < c.position
      assert Enum.map(Queue.list_items(), & &1.title) == ["A", "B", "C"]
    end

    test "stores the local flag" do
      {:ok, item} = Queue.enqueue(attrs(%{local: true, url: "/home/vids/clip.mp4"}))
      assert item.local == true
    end

    test "stores the author (channel), so it survives a reload for the player" do
      {:ok, item} = Queue.enqueue(attrs(%{author: "Some Channel"}))
      assert item.author == "Some Channel"
    end

    test "rejects an item missing a required field" do
      assert {:error, changeset} = Queue.enqueue(%{title: "no url"})
      refute changeset.valid?
    end
  end

  describe "list_items/0 and head/0" do
    test "list is ordered by position, head is the first" do
      {:ok, _a} = Queue.enqueue(attrs(%{title: "A", url: "u-a"}))
      {:ok, _b} = Queue.enqueue(attrs(%{title: "B", url: "u-b"}))

      assert Enum.map(Queue.list_items(), & &1.title) == ["A", "B"]
      assert Queue.head().title == "A"
    end

    test "head is nil on an empty queue" do
      assert Queue.head() == nil
      assert Queue.list_items() == []
    end
  end

  describe "enqueue_next/1" do
    test "on an empty queue the item becomes the head" do
      {:ok, _} = Queue.enqueue_next(attrs(%{title: "A", url: "u-a"}))
      assert Enum.map(Queue.list_items(), & &1.title) == ["A"]
    end

    test "on a single-item queue the item lands second" do
      {:ok, _a} = Queue.enqueue(attrs(%{title: "A", url: "u-a"}))
      {:ok, _b} = Queue.enqueue_next(attrs(%{title: "B", url: "u-b"}))
      assert Enum.map(Queue.list_items(), & &1.title) == ["A", "B"]
    end

    test "inserts right after the head, before the rest of the tail" do
      {:ok, _a} = Queue.enqueue(attrs(%{title: "A", url: "u-a"}))
      {:ok, _b} = Queue.enqueue(attrs(%{title: "B", url: "u-b"}))
      {:ok, _c} = Queue.enqueue(attrs(%{title: "C", url: "u-c"}))

      {:ok, _n} = Queue.enqueue_next(attrs(%{title: "N", url: "u-n"}))
      assert Enum.map(Queue.list_items(), & &1.title) == ["A", "N", "B", "C"]
    end

    test "tolerates non-contiguous positions left by a delete" do
      {:ok, a} = Queue.enqueue(attrs(%{title: "A", url: "u-a"}))
      {:ok, _b} = Queue.enqueue(attrs(%{title: "B", url: "u-b"}))
      {:ok, _c} = Queue.enqueue(attrs(%{title: "C", url: "u-c"}))
      {:ok, _} = Queue.remove(a)

      {:ok, _n} = Queue.enqueue_next(attrs(%{title: "N", url: "u-n"}))
      assert Enum.map(Queue.list_items(), & &1.title) == ["B", "N", "C"]
    end

    test "returns the insert error without promoting" do
      assert {:error, changeset} = Queue.enqueue_next(%{title: "no url"})
      refute changeset.valid?
      assert Queue.list_items() == []
    end
  end

  describe "remove/1" do
    test "removes one item and leaves the rest ordered" do
      {:ok, a} = Queue.enqueue(attrs(%{title: "A", url: "u-a"}))
      {:ok, _b} = Queue.enqueue(attrs(%{title: "B", url: "u-b"}))

      assert {:ok, _} = Queue.remove(a)
      assert Enum.map(Queue.list_items(), & &1.title) == ["B"]
    end
  end

  describe "clear/0" do
    test "empties the queue" do
      {:ok, _} = Queue.enqueue(attrs())
      {:ok, _} = Queue.enqueue(attrs(%{url: "u-2"}))

      assert :ok = Queue.clear()
      assert Queue.list_items() == []
    end
  end

  describe "move_up/1 and move_down/1" do
    setup do
      {:ok, a} = Queue.enqueue(attrs(%{title: "A", url: "u-a"}))
      {:ok, b} = Queue.enqueue(attrs(%{title: "B", url: "u-b"}))
      {:ok, c} = Queue.enqueue(attrs(%{title: "C", url: "u-c"}))
      {:ok, a: a, b: b, c: c}
    end

    test "move_up swaps an item towards the head", %{b: b} do
      assert :ok = Queue.move_up(b)
      assert Enum.map(Queue.list_items(), & &1.title) == ["B", "A", "C"]
    end

    test "move_down swaps an item towards the tail", %{b: b} do
      assert :ok = Queue.move_down(b)
      assert Enum.map(Queue.list_items(), & &1.title) == ["A", "C", "B"]
    end

    test "move_up at the head is a no-op", %{a: a} do
      assert :ok = Queue.move_up(a)
      assert Enum.map(Queue.list_items(), & &1.title) == ["A", "B", "C"]
    end

    test "move_down at the tail is a no-op", %{c: c} do
      assert :ok = Queue.move_down(c)
      assert Enum.map(Queue.list_items(), & &1.title) == ["A", "B", "C"]
    end
  end
end
