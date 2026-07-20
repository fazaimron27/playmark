defmodule Playmark.Metadata do
  @moduledoc """
  Fetches YouTube video metadata without an API key.

  Uses YouTube's public oEmbed endpoint, which returns JSON containing the
  video `title` and `author_name` (the channel) for any public video.
  """

  @oembed "https://www.youtube.com/oembed"

  @doc """
  Fetches metadata for a YouTube URL.

  Returns `{:ok, %{title: String.t(), channel: String.t()}}` on success, or
  `{:error, reason}` if the request fails or the video is unavailable.
  """
  def fetch(url) when is_binary(url) do
    case Req.get(@oembed, params: [url: url, format: "json"]) do
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
