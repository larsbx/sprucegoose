defmodule SpruceGoose.AuthorityRuntime do
  @moduledoc """
  Refuses direct CLI execution on a host delegated to another authority.

  The thin socket client does not load this application. A compiled escript or
  `mix run` does, so the marker prevents accidental writes to retained rollback
  databases while the named remote host is authoritative.
  """

  def ensure_local_execution_allowed do
    path =
      Application.get_env(
        :spruce_goose,
        :authority_host_marker,
        "/home/admin-papa/.config/sprucegoose/authority-host"
      )

    case File.read(path) do
      {:error, :enoent} ->
        :ok

      {:ok, value} ->
        delegated(value)

      {:error, reason} ->
        {:error, "cannot verify authority host marker: #{:file.format_error(reason)}"}
    end
  end

  defp delegated(value) do
    case String.trim(value) do
      "" ->
        {:error, "authority host marker is empty; refusing direct execution"}

      "local" ->
        :ok

      host ->
        {:error,
         "direct SpruceGoose execution is disabled; authority is #{host}; use the supported socket client"}
    end
  end
end
