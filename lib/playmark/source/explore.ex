defmodule Playmark.Source.Explore do
  @moduledoc """
  Fetches YouTube's recommended feed for the Explore overlay.

  Unlike channel and search listings, YouTube's homepage can contain playlists,
  channels, and navigation shelves alongside videos. The print format therefore
  includes the extractor type and emitted URL, and `parse_videos/1` keeps only
  entries that are directly playable YouTube videos.
  """

  alias Playmark.Source.Channel

  @sep "\x1F"
  @homepage_url "https://www.youtube.com"
  @default_limit 20
  @default_socket_timeout 30

  @doc """
  Returns up to the configured number of recommendations from YouTube's homepage.
  """
  def homepage(limit \\ limit()) when is_integer(limit) and limit > 0 do
    case System.cmd("yt-dlp", build_args(limit), stderr_to_stdout: true) do
      {output, 0} -> {:ok, output |> parse_videos() |> Channel.enrich_titles()}
      {output, code} -> {:error, "yt-dlp failed (exit #{code}): #{String.trim(output)}"}
    end
  end

  @doc "Builds the `yt-dlp` arguments used to read the recommended feed."
  def build_args(limit) when is_integer(limit) and limit > 0 do
    [
      "--socket-timeout",
      socket_timeout(),
      "--playlist-end",
      Integer.to_string(limit),
      "--flat-playlist",
      "--print",
      "%(extractor_key)s#{@sep}%(id)s#{@sep}%(title)s#{@sep}%(live_status)s#{@sep}%(duration)s#{@sep}%(view_count)s#{@sep}%(url)s",
      @homepage_url
    ]
  end

  @doc """
  Parses Explore's line-oriented output, dropping non-video homepage cards.
  """
  def parse_videos(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_line(line) do
    case String.split(String.trim(line), @sep, parts: 7) do
      ["Youtube", id, title, status, duration, views, url] ->
        build_video(id, title, status, duration, views, url)

      _other ->
        nil
    end
  end

  defp build_video(id, title, status, duration, views, url) do
    if valid_video_id?(id) and title not in ["", "NA"] and playable_url?(url, id) do
      %{
        id: id,
        title: title,
        url: url,
        live: live_status(status),
        duration: parse_int(duration),
        views: parse_int(views)
      }
    end
  end

  defp valid_video_id?(id), do: Regex.match?(~r/^[A-Za-z0-9_-]{11}$/, id)

  defp playable_url?(url, id) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: "/watch", query: query}
      when scheme in ["http", "https"] and
             host in ["youtube.com", "www.youtube.com", "m.youtube.com"] ->
        query != nil and URI.decode_query(query)["v"] == id

      %URI{scheme: scheme, host: host, path: path}
      when scheme in ["http", "https"] and
             host in ["youtube.com", "www.youtube.com", "m.youtube.com"] ->
        path == "/shorts/#{id}" or String.starts_with?(path || "", "/shorts/#{id}/")

      %URI{scheme: scheme, host: "youtu.be", path: path} when scheme in ["http", "https"] ->
        path == "/#{id}"

      _other ->
        false
    end
  end

  defp live_status("is_live"), do: :live
  defp live_status("was_live"), do: :ended
  defp live_status("post_live"), do: :ended
  defp live_status("is_upcoming"), do: :upcoming
  defp live_status(_other), do: :none

  defp parse_int(value) when value in [nil, "", "NA"], do: nil

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp limit, do: Application.get_env(:playmark, :explore_limit, @default_limit)

  defp socket_timeout,
    do: to_string(Application.get_env(:playmark, :socket_timeout, @default_socket_timeout))
end
