defmodule Playmark.Source.Metadata do
  @moduledoc """
  Fetches YouTube video metadata without an API key.

  Uses YouTube's public oEmbed endpoint, which returns JSON containing the
  video `title` and `author_name` (the channel) for any public video.
  """

  @oembed "https://www.youtube.com/oembed"

  # Bound the oEmbed request so the direct callers (adding/bookmarking, which run
  # in the :fetching state) get a prompt failure instead of hanging. Req retries
  # transient errors with backoff by default, which would stack on top of this —
  # a single fast attempt matches the "best-effort, fail quick" nature of the
  # lookup, and title enrichment already tolerates a miss. (In enrich_titles the
  # Task.async_stream timeout also bounds this; here it's the whole budget.)
  @receive_timeout_ms 4_000

  @doc """
  Fetches metadata for a YouTube URL.

  Returns `{:ok, %{title: String.t(), channel: String.t()}}` on success, or
  `{:error, reason}` if the request fails or the video is unavailable.
  """
  def fetch(url) when is_binary(url) do
    opts = [
      params: [url: url, format: "json"],
      receive_timeout: @receive_timeout_ms,
      retry: false
    ]

    case Req.get(@oembed, opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok,
         %{
           title: Map.get(body, "title", url),
           channel: Map.get(body, "author_name", "Unknown")
         }}

      {:ok, %Req.Response{status: status}} ->
        {:error, "oEmbed request failed with status #{status} (is the video public?)"}

      {:error, reason} ->
        {:error, "oEmbed request error: #{inspect(reason)}"}
    end
  end
end
