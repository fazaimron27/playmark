defmodule Playmark.SubscriptionsTest do
  use Playmark.DataCase, async: false

  alias Playmark.{Subscription, Subscriptions}

  describe "list_subscriptions/0" do
    test "returns subscriptions newest first" do
      older = insert_subscription("https://youtube.com/@a", "Older", ~N[2026-01-01 00:00:00])
      newer = insert_subscription("https://youtube.com/@b", "Newer", ~N[2026-02-01 00:00:00])

      assert [first, second] = Subscriptions.list_subscriptions()
      assert first.id == newer.id
      assert second.id == older.id
    end
  end

  describe "delete_subscription/1" do
    test "removes the subscription" do
      subscription = insert_subscription("https://youtube.com/@c", "Doomed")

      assert {:ok, _} = Subscriptions.delete_subscription(subscription)
      assert Subscriptions.list_subscriptions() == []
    end
  end

  defp insert_subscription(url, name, inserted_at \\ ~N[2026-01-15 00:00:00]) do
    Repo.insert!(%Subscription{
      url: url,
      name: name,
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
  end
end
