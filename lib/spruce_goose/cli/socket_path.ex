defmodule SpruceGoose.CLI.SocketPath do
  @moduledoc false

  use GenServer

  def start_link(path), do: GenServer.start_link(__MODULE__, path)

  def remove(path), do: remove_managed_socket(path)

  @impl true
  def init(path) do
    with :ok <- remove_managed_socket(path) do
      {:ok, path}
    end
  end

  @impl true
  def terminate(_reason, path) do
    _ = remove_managed_socket(path)
    :ok
  end

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
