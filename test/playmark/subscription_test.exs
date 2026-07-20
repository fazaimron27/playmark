defmodule Playmark.SubscriptionTest do
  use ExUnit.Case, async: true

  alias Playmark.Subscription

  describe "changeset/2" do
    test "is valid with url and name" do
      changeset =
        Subscription.changeset(%Subscription{}, %{
          url: "https://www.youtube.com/@handle/videos",
          name: "A Channel"
        })

      assert changeset.valid?
    end

    test "requires url and name" do
      changeset = Subscription.changeset(%Subscription{}, %{})

      assert %{url: ["can't be blank"], name: ["can't be blank"]} = errors(changeset)
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
