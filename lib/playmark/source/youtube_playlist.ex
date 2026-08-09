defmodule Playmark.Source.YouTubePlaylist do
  @moduledoc """
  Resolves YouTube playlist metadata and current entries with `yt-dlp`.

  Playlist entries are read with `--flat-playlist`, so listing never resolves or
  downloads the media streams. Each accepted entry is converted to a canonical
  single-video watch URL before it reaches playback.
  """

  @sep "\x1F"
  @default_limit 100
  @default_socket_timeout 30

  @doc "Resolves a playlist title and owner without downloading media."
  def metadata(url) when is_binary(url) do
    case System.cmd("yt-dlp", metadata_args(url), stderr_to_stdout: true) do
      {output, 0} -> parse_metadata(output)
      {output, code} -> {:error, command_error(output, code)}
    end
  end

  @doc "Lists up to the configured number of currently available playlist videos."
  def list_videos(url, limit \\ limit())
      when is_binary(url) and is_integer(limit) and limit > 0 do
    case System.cmd("yt-dlp", build_args(url, limit), stderr_to_stdout: true) do
      {output, 0} -> {:ok, parse_videos(output)}
      {output, code} -> {:error, command_error(output, code)}
    end
  end

  @doc "Builds the bounded metadata command arguments."
  def metadata_args(url) when is_binary(url) do
    [
      "--socket-timeout",
      socket_timeout(),
      "--flat-playlist",
      "--playlist-end",
      "1",
      "--no-warnings",
      "--dump-single-json",
      url
    ]
  end

  @doc "Builds the bounded flat-playlist entry command arguments."
  def build_args(url, limit) when is_binary(url) and is_integer(limit) and limit > 0 do
    [
      "--socket-timeout",
      socket_timeout(),
      "--playlist-end",
      Integer.to_string(limit),
      "--flat-playlist",
      "--print",
      "%(extractor_key)s#{@sep}%(id)s#{@sep}%(title)s#{@sep}%(live_status)s#{@sep}%(duration)s#{@sep}%(view_count)s#{@sep}%(channel)s",
      url
    ]
  end

  @doc "Parses a playlist-level JSON object returned by `--dump-single-json`."
  def parse_metadata(output) when is_binary(output) do
    with {:ok, data} <- Jason.decode(String.trim(output)),
         title when is_binary(title) and title not in ["", "NA"] <- data["title"] do
      {:ok, %{title: title, channel: present(data["channel"] || data["uploader"])}}
    else
      _ -> {:error, "could not read playlist metadata"}
    end
  end

  @doc "Parses flat playlist entries, preserving their emitted order."
  def parse_videos(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_line(line) do
    case String.split(String.trim(line), @sep, parts: 7) do
      ["Youtube", id, title, status, duration, views, channel] ->
        build_video(id, title, status, duration, views, channel)

      _ ->
        nil
    end
  end

  defp build_video(id, title, status, duration, views, channel) do
    if valid_video_id?(id) and available_title?(title) do
      %{
        id: id,
        title: title,
        url: "https://www.youtube.com/watch?v=#{id}",
        live: live_status(status),
        duration: parse_int(duration),
        views: parse_int(views),
        author: present(channel)
      }
    end
  end

  defp valid_video_id?(id), do: Regex.match?(~r/^[A-Za-z0-9_-]{11}$/, id)

  defp available_title?(title) do
    title not in ["", "NA", "[Private video]", "[Deleted video]"]
  end

  defp present(value) when value in [nil, "", "NA"], do: nil
  defp present(value), do: value

  defp parse_int(value) when value in [nil, "", "NA"], do: nil

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp live_status("is_live"), do: :live
  defp live_status("was_live"), do: :ended
  defp live_status("post_live"), do: :ended
  defp live_status("is_upcoming"), do: :upcoming
  defp live_status(_), do: :none

  defp command_error(output, code),
    do: "yt-dlp failed (exit #{code}): #{String.trim(output)}"

  defp limit, do: Application.get_env(:playmark, :playlist_limit, @default_limit)

  defp socket_timeout,
    do: to_string(Application.get_env(:playmark, :socket_timeout, @default_socket_timeout))
end
