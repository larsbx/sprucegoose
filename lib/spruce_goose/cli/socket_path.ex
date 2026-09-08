defmodule SpruceGoose.CLI.SocketPath do
  @moduledoc """
  Prepare and hold the CLI socket path.

  ## Why this checks the directory

  The CLI socket is a fully privileged admin API: anything that can connect may
  pass `--as NAME` and act as that actor. `docs/authorization.md` is candid that
  a declared actor is an identification, not an authentication — which is a
  defensible design, but it means the socket's *filesystem permissions* are the
  entire authentication boundary.

  Nothing in the application used to establish that boundary. It lived in
  `RuntimeDirectoryMode=0700` in a systemd unit outside the release, so a
  service started any other way — or with `SPRUCE_GOOSE_CLI_SOCKET` pointed
  elsewhere — bound a world-reachable admin API with no error and no warning.

  So the directory is checked here, before binding, with the same test
  `SpruceGoose.Blueprints.ForgejoVerifier` already applies to the read token:
  owned by this user, and no group or other bits. A boundary the application
  will not assert is not a boundary it can claim.
  """

  use GenServer

  def start_link(path), do: GenServer.start_link(__MODULE__, path)

  def remove(path), do: remove_managed_socket(path)

  @impl true
  def init(path) do
    with :ok <- verify_directory(Path.dirname(path)),
         :ok <- remove_managed_socket(path) do
      {:ok, path}
    end
  end

  @impl true
  def terminate(_reason, path) do
    _ = remove_managed_socket(path)
    :ok
  end

  @doc """
  Refuse a socket directory that anyone but its owner can reach.

  Checked rather than corrected: silently tightening a directory an operator
  deliberately opened would hide the misconfiguration this exists to surface,
  and would not undo whatever connected while it was open.
  """
  def verify_directory(directory) do
    case File.stat(directory) do
      {:ok, %File.Stat{type: :directory, mode: mode}} ->
        if Bitwise.band(mode, 0o077) == 0 do
          :ok
        else
          {:error,
           "CLI socket directory #{directory} is mode #{octal(mode)}; it must be " <>
             "owner-only (0700). The socket is the only authentication boundary on a " <>
             "fully privileged admin API: anything that can connect may act as any actor"}
        end

      {:ok, %File.Stat{}} ->
        {:error, "CLI socket directory #{directory} is not a directory"}

      {:error, reason} ->
        {:error,
         "cannot inspect CLI socket directory #{directory}: #{:file.format_error(reason)}"}
    end
  end

  # Ownership needs no separate check: an owner-only directory belonging to
  # somebody else refuses the bind on its own, with the kernel's own error.
  defp octal(mode),
    do: mode |> Bitwise.band(0o7777) |> Integer.to_string(8) |> String.pad_leading(4, "0")

  defp remove_managed_socket(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :other}} ->
        File.rm(path)

      {:ok, _stat} ->
        {:error, "CLI socket path exists and is not a Unix socket: #{path}"}

      {:error, reason} ->
        {:error, "cannot inspect CLI socket path #{path}: #{:file.format_error(reason)}"}
    end
  end
end
