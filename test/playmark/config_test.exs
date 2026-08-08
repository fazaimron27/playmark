defmodule Playmark.ConfigTest do
  # Not async: load/0 mutates the :playmark application env.
  use ExUnit.Case, async: false

  alias Playmark.Config

  describe "parse/1" do
    test "reads key = value pairs, trimming whitespace" do
      assert Config.parse("player = vlc\nsearch_limit=5") ==
               %{"player" => "vlc", "search_limit" => "5"}
    end

    test "skips blank lines and full-line comments" do
      contents = """
      # a comment
      player = mpv

      # another
      channel_limit = 10
      """

      assert Config.parse(contents) == %{"player" => "mpv", "channel_limit" => "10"}
    end

    test "strips trailing inline comments" do
      assert Config.parse("player = vlc  # use vlc") == %{"player" => "vlc"}
    end

    test "ignores lines without an = separator" do
      assert Config.parse("garbage line\nplayer = mpv") == %{"player" => "mpv"}
    end

    test "keeps only the value up to the first = (values may contain =)" do
      assert Config.parse("player = a=b") == %{"player" => "a=b"}
    end

    test "last duplicate key wins" do
      assert Config.parse("player = mpv\nplayer = vlc") == %{"player" => "vlc"}
    end
  end

  describe "load/0" do
    setup do
      keys = [
        :player,
        :max_height,
        :subtitles,
        :subtitle_default,
        :subtitle_fallback,
        :subtitle_translate,
        :search_limit,
        :explore_limit,
        :playlist_limit,
        :channel_limit,
        :oembed_timeout_ms,
        :oembed_concurrency,
        :socket_timeout
      ]

      original = Enum.map(keys, fn key -> {key, Application.fetch_env(:playmark, key)} end)

      # The :config_path override (see below) redirects Config.path/0 at a temp
      # file so tests never read or write the user's real ~/.config/playmark. Always
      # clear it afterward.
      on_exit(fn ->
        Application.delete_env(:playmark, :config_path)

        Enum.each(original, fn
          {key, {:ok, value}} -> Application.put_env(:playmark, key, value)
          {key, :error} -> Application.delete_env(:playmark, key)
        end)
      end)

      :ok
    end

    test "a missing file is a no-op" do
      # Point Config.path/0 at a temp file that does not exist; loading it must not
      # crash and must not set anything. The override keeps this independent of any
      # real ~/.config/playmark/config.env on the machine running the suite.
      missing =
        Path.join(System.tmp_dir!(), "playmark-absent-#{System.unique_integer([:positive])}.env")

      refute File.exists?(missing)
      Application.put_env(:playmark, :config_path, missing)

      Application.delete_env(:playmark, :player)
      assert Config.load() == :ok
      assert Application.fetch_env(:playmark, :player) == :error
    end

    test "applies recognized settings from a file, coercing types" do
      contents = """
      player = vlc
      max_height = 720
      subtitles = false
      subtitle_default = id
      subtitle_fallback = en
      search_limit = 5
      explore_limit = 8
      playlist_limit = 100
      channel_limit = 12
      oembed_timeout_ms = 2000
      oembed_concurrency = 4
      socket_timeout = 45
      """

      in_tmp_config(contents, fn ->
        assert Config.load() == :ok

        assert Application.get_env(:playmark, :player) == :vlc
        assert Application.get_env(:playmark, :max_height) == 720
        assert Application.get_env(:playmark, :subtitles) == false
        assert Application.get_env(:playmark, :subtitle_default) == "id"
        assert Application.get_env(:playmark, :subtitle_fallback) == "en"
        assert Application.get_env(:playmark, :search_limit) == 5
        assert Application.get_env(:playmark, :explore_limit) == 8
        assert Application.get_env(:playmark, :playlist_limit) == 100
        assert Application.get_env(:playmark, :channel_limit) == 12
        assert Application.get_env(:playmark, :oembed_timeout_ms) == 2000
        assert Application.get_env(:playmark, :oembed_concurrency) == 4
        assert Application.get_env(:playmark, :socket_timeout) == 45
      end)
    end

    test "coerces subtitles booleans and rejects an invalid one" do
      in_tmp_config("subtitles = yes\n", fn ->
        assert Config.load() == :ok
        assert Application.get_env(:playmark, :subtitles) == true
      end)

      Application.put_env(:playmark, :subtitles, true)

      in_tmp_config("subtitles = maybe\n", fn ->
        assert Config.load() == :ok
        assert Application.get_env(:playmark, :subtitles) == true
      end)
    end

    test "reads subtitle_default and subtitle_fallback as strings" do
      in_tmp_config("subtitle_default = id\nsubtitle_fallback = en\n", fn ->
        assert Config.load() == :ok
        assert Application.get_env(:playmark, :subtitle_default) == "id"
        assert Application.get_env(:playmark, :subtitle_fallback) == "en"
      end)
    end

    test "reads subtitle_translate as a boolean" do
      in_tmp_config("subtitle_translate = off\n", fn ->
        assert Config.load() == :ok
        assert Application.get_env(:playmark, :subtitle_translate) == false
      end)
    end

    test "rejects an empty subtitle_default, keeping the existing value" do
      Application.put_env(:playmark, :subtitle_default, "en")

      in_tmp_config("subtitle_default =\n", fn ->
        assert Config.load() == :ok
        assert Application.get_env(:playmark, :subtitle_default) == "en"
      end)
    end

    test "an invalid value for a known key leaves the existing value untouched" do
      Application.put_env(:playmark, :player, :mpv)
      Application.put_env(:playmark, :search_limit, 20)

      in_tmp_config("player = betamax\nsearch_limit = -3\n", fn ->
        assert Config.load() == :ok
        assert Application.get_env(:playmark, :player) == :mpv
        assert Application.get_env(:playmark, :search_limit) == 20
      end)
    end

    test "unknown keys are ignored" do
      in_tmp_config("nonsense = 1\nplayer = vlc\n", fn ->
        assert Config.load() == :ok
        assert Application.get_env(:playmark, :player) == :vlc
      end)
    end

    test "coerces the ffplay player" do
      Application.delete_env(:playmark, :player)

      in_tmp_config("player = ffplay\n", fn ->
        assert Config.load() == :ok
        assert Application.get_env(:playmark, :player) == :ffplay
      end)
    end
  end

  # Writes `contents` to an isolated temp file and points Config.path/0 at it via
  # the :config_path override for the duration of `fun`. This never touches the
  # user's real ~/.config/playmark/config.env — the override is cleared in setup's
  # on_exit, and the temp file lives under a unique dir we remove here.
  defp in_tmp_config(contents, fun) do
    dir =
      Path.join(System.tmp_dir!(), "playmark-config-test-#{System.unique_integer([:positive])}")

    path = Path.join(dir, "config.env")
    File.mkdir_p!(dir)
    File.write!(path, contents)
    Application.put_env(:playmark, :config_path, path)

    try do
      fun.()
    after
      File.rm_rf!(dir)
    end
  end
end
