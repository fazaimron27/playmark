defmodule Playmark.Presence.SocketTest do
  use ExUnit.Case, async: true

  alias Playmark.Presence.Socket

  defp tmp_path do
    Path.join(System.tmp_dir!(), "playmark-socket-#{System.unique_integer([:positive])}")
  end

  describe "candidates/1" do
    test "starts with discord-ipc-0 in the highest-precedence directory" do
      env = %{"XDG_RUNTIME_DIR" => "/run/user/1000"}
      assert hd(Socket.candidates(env)) == "/run/user/1000/discord-ipc-0"
    end

    test "tries discord-ipc-0 through discord-ipc-9" do
      candidates = Socket.candidates(%{"XDG_RUNTIME_DIR" => "/run/user/1000"})
      assert "/run/user/1000/discord-ipc-9" in candidates
      refute "/run/user/1000/discord-ipc-10" in candidates
    end

    test "orders directories XDG_RUNTIME_DIR, TMPDIR, TMP, TEMP, then /tmp" do
      env = %{
        "XDG_RUNTIME_DIR" => "/xdg",
        "TMPDIR" => "/tmpdir",
        "TMP" => "/tmpvar",
        "TEMP" => "/tempvar"
      }

      # The expectation is composed from literals rather than dumped as ~200
      # path strings, but it is still a full-list assertion: the directory
      # precedence, the subdirectory list, and the 0..9 name range are all
      # spelled out here, so a reordering anywhere inside the middle fails —
      # which an `in`/`hd` check would not catch. That assertion is the point
      # of this test; the composition is only there to keep it readable.
      dirs = ["/xdg", "/tmpdir", "/tmpvar", "/tempvar", "/tmp"]
      subdirs = ["", "app/com.discordapp.Discord", "snap.discord", "discord"]

      expected =
        for dir <- dirs, sub <- subdirs, n <- 0..9 do
          if sub == "", do: "#{dir}/discord-ipc-#{n}", else: "#{dir}/#{sub}/discord-ipc-#{n}"
        end

      assert Socket.candidates(env) == expected
    end

    test "skips empty environment values" do
      env = %{"XDG_RUNTIME_DIR" => "", "TMPDIR" => "", "TMP" => ""}
      assert hd(Socket.candidates(env)) == "/tmp/discord-ipc-0"
    end

    test "includes the Flatpak, Snap, and discord subdirectories" do
      candidates = Socket.candidates(%{"XDG_RUNTIME_DIR" => "/xdg"})

      assert "/xdg/app/com.discordapp.Discord/discord-ipc-0" in candidates
      assert "/xdg/snap.discord/discord-ipc-0" in candidates
      assert "/xdg/discord/discord-ipc-0" in candidates
    end

    test "deduplicates a directory named twice without reordering" do
      candidates = Socket.candidates(%{"XDG_RUNTIME_DIR" => "/tmp", "TMP" => "/tmp"})

      assert Enum.uniq(candidates) == candidates

      # Naming /tmp twice must produce exactly the list a bare /tmp produces —
      # not that list with a second copy pushed onto the end. Comparing against
      # the single-directory result pins that; `List.last == "/tmp/discord-ipc-9"`
      # did not, because the last candidate is under the /tmp/discord subdir.
      assert candidates == Socket.candidates(%{})
      assert List.last(candidates) == "/tmp/discord/discord-ipc-9"
    end
  end

  describe "trusted?/2" do
    test "accepts a path owned by the expected uid" do
      path = tmp_path()
      File.write!(path, "")
      on_exit(fn -> File.rm(path) end)

      assert Socket.trusted?(path, File.stat!(path).uid)
    end

    test "refuses a path owned by another uid" do
      path = tmp_path()
      File.write!(path, "")
      on_exit(fn -> File.rm(path) end)

      refute Socket.trusted?(path, File.stat!(path).uid + 1)
    end

    test "refuses a path that does not exist" do
      refute Socket.trusted?(tmp_path(), 0)
    end
  end

  describe "current_uid/0" do
    test "returns the uid that owns this process's /proc entry" do
      assert Socket.current_uid() == File.stat!("/proc/self").uid
    end
  end
end
