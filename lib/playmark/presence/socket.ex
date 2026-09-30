defmodule Playmark.Presence.Socket do
  @moduledoc """
  Finds Discord's local IPC socket, and decides whether it may be trusted.

  Discord listens on a Unix domain socket named `discord-ipc-N` in one of a few
  directories. This module answers two questions and nothing else: *where might
  it be*, and *is the thing at that path ours*.

  ## Why the trust check exists

  The discovery fallback includes `/tmp`, which is world-writable. Without a
  check, any local user could plant a `discord-ipc-0` and receive our activity,
  or feed us replies. `trusted?/2` requires the socket to be owned by our own
  uid.

  The reference implementation uses `SO_PEERCRED`, which is strictly stronger —
  it cannot be raced by swapping the filesystem entry between the check and the
  connect. The `stat` check is chosen because it needs no NIF and no raw socket
  option, and the window it leaves open requires the attacker to already have
  write access to `$XDG_RUNTIME_DIR`, which is not world-writable. This is a
  deliberate, documented weakening, not an oversight.

  ## Linux only

  `:gen_tcp.connect({:local, path}, 0, ...)` is how the connection is made, and
  it cannot address Windows named pipes (`\\\\.\\pipe\\discord-ipc-N`). On
  Windows this module finds nothing and presence reports unavailable. That is a
  known bound, not a bug to work around.
  """

  # Discord's socket names, in the order Discord itself probes them.
  @socket_names Enum.map(0..9, &"discord-ipc-#{&1}")

  # The directory itself, then the subdirectories Flatpak, Snap, and Discord's
  # own sandboxed install use. "" is the directory itself.
  @subdirs ["", "app/com.discordapp.Discord", "snap.discord", "discord"]

  # Environment variables that may hold a runtime directory, highest precedence
  # first, with /tmp as the unconditional last resort.
  @env_keys ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"]

  @doc """
  Candidate socket paths, in the order they should be tried.

  Order is load-bearing for diagnostics: the first candidate that exists and is
  refused is the one worth naming, and naming the last candidate tried reports a
  path that may never have existed. `Playmark.Presence.Client` does not name
  paths in its user-facing error at all; `mix playmark.debug --presence` prints
  this list in order, which is where the rule is observed.

  Takes `env` as an argument so tests inject a fake environment rather than
  mutating the real one.
  """
  def candidates(env \\ System.get_env()) do
    for dir <- dirs(env), sub <- @subdirs, name <- @socket_names, uniq: true do
      join(dir, sub, name)
    end
  end

  @doc """
  True when `path` exists and is owned by `uid`.

  A path whose `stat` fails — missing, unreadable, a broken symlink — is not
  trusted, which is the safe answer.
  """
  def trusted?(path, uid \\ nil) do
    uid = uid || current_uid()

    case File.stat(path) do
      {:ok, %File.Stat{uid: ^uid}} -> true
      _other -> false
    end
  end

  @doc """
  This process's uid, or `-1` when it cannot be determined.

  `/proc/self` is the cheap, correct answer on Linux — it resolves to this
  process's directory, which is owned by us. Elsewhere (macOS, BSD) it does not
  exist, so `id -u` is the fallback. When both fail the answer is `-1`, which
  matches no file, so `trusted?/2` refuses everything and presence reports
  unavailable rather than trusting a socket it cannot vouch for.
  """
  def current_uid do
    case File.stat("/proc/self") do
      {:ok, %File.Stat{uid: uid}} -> uid
      _other -> uid_from_id()
    end
  end

  defp uid_from_id do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {uid, ""} -> uid
          _other -> -1
        end

      _other ->
        -1
    end
  end

  defp dirs(env) do
    from_env = for key <- @env_keys, value = env[key], value not in [nil, ""], do: value
    Enum.uniq(from_env ++ ["/tmp"])
  end

  defp join(dir, "", name), do: Path.join(dir, name)
  defp join(dir, sub, name), do: Path.join([dir, sub, name])
end
