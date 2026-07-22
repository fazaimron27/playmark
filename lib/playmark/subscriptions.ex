defmodule Playmark.Subscriptions do
  @moduledoc """
  Context for creating and listing channel subscriptions.

  A subscription stores only the channel URL and name. The channel's videos are
  never stored — they're fetched live via `Playmark.Channel` each time the
  subscription is opened, so the list is always current.
  """

  import Ecto.Query, only: [from: 2]

  alias Playmark.{Channel, Repo, Subscription, YouTube}

  @doc """
  Lists all subscriptions, newest first.
  """
  def list_subscriptions do
    Repo.all(from(s in Subscription, order_by: [desc: s.inserted_at]))
  end

  @doc """
  Resolves the channel's name for the given URL and stores a subscription.

  Returns `{:ok, subscription}` or `{:error, reason}`.
  """
  def add_subscription(url) when is_binary(url) do
    url = url |> String.trim() |> YouTube.canonical_channel_url()

    with {:ok, _} <- YouTube.validate(url),
         {:ok, name} <- channel().name(url) do
      %Subscription{}
      |> Subscription.changeset(%{url: url, name: name})
      |> Repo.insert()
    end
  end

  @doc """
  Deletes a subscription.
  """
  def delete_subscription(%Subscription{} = subscription) do
    Repo.delete(subscription)
  end

  # The channel name lookup shells out to yt-dlp; swappable in tests via the
  # :channel_impl seam (default Playmark.Channel), like the TUI uses.
  defp channel, do: Application.get_env(:playmark, :channel_impl, Channel)
end
