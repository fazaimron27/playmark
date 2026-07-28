defmodule Playmark.SubscriptionsTest do
  use Playmark.DataCase, async: false

  alias Playmark.{Subscription, Subscriptions}

  describe "list_subscriptions/0" do
    test "returns subscriptions by channel name ascending, regardless of insertion date" do
      alpha = insert_subscription("https://youtube.com/@a", "Alpha", ~N[2026-01-01 00:00:00])
      zulu = insert_subscription("https://youtube.com/@z", "Zulu", ~N[2026-02-01 00:00:00])

      assert [first, second] = Subscriptions.list_subscriptions()
      assert first.id == alpha.id
      assert second.id == zulu.id
    end
  end

  describe "delete_subscription/1" do
    test "removes the subscription" do
      subscription = insert_subscription("https://youtube.com/@c", "Doomed")

      assert {:ok, _} = Subscriptions.delete_subscription(subscription)
      assert Subscriptions.list_subscriptions() == []
    end
  end

  describe "add_subscription/1" do
    setup do
      # Stub the channel-name lookup so add_subscription doesn't shell out to
      # yt-dlp. It echoes the URL it was handed back as the name, so a test can
      # assert what URL reached the network layer after normalization.
      Application.put_env(:playmark, :channel_impl, StubNameChannel)
      on_exit(fn -> Application.delete_env(:playmark, :channel_impl) end)
    end

    test "stores the canonical (tab-stripped) channel URL" do
      assert {:ok, sub} =
               Subscriptions.add_subscription("https://www.youtube.com/@AmmarTV/videos")

      assert sub.url == "https://www.youtube.com/@AmmarTV"

      assert {:ok, sub2} =
               Subscriptions.add_subscription("https://www.youtube.com/@Other/streams")

      assert sub2.url == "https://www.youtube.com/@Other"
    end

    test "trims surrounding whitespace before storing" do
      assert {:ok, sub} =
               Subscriptions.add_subscription("  https://www.youtube.com/@AmmarTV  ")

      assert sub.url == "https://www.youtube.com/@AmmarTV"
    end

    test "leaves an already-bare channel URL unchanged" do
      url = "https://www.youtube.com/@AmmarTV"
      assert {:ok, sub} = Subscriptions.add_subscription(url)
      assert sub.url == url
    end

    test "rejects a non-YouTube URL before any lookup" do
      assert {:error, _} = Subscriptions.add_subscription("https://vimeo.com/12345")
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

defmodule StubNameChannel do
  @moduledoc false
  # Returns the URL it was given as the channel name, so a test can read back the
  # exact (normalized) URL that reached the name lookup.
  def name(url), do: {:ok, "Name for #{url}"}
end
