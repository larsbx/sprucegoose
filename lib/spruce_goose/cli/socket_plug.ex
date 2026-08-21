defmodule SpruceGoose.CLI.SocketPlug do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  @max_body_bytes 65_536
  @max_args 128
  @max_arg_bytes 4_096

  @impl Plug
  def init(opts) do
    %{
      runner: Keyword.get(opts, :runner, &SpruceGoose.CLI.run/1),
      supervisor: Keyword.get(opts, :supervisor, SpruceGoose.CLI.TaskSupervisor),
      timeout: Keyword.get(opts, :timeout, 30_000)
    }
  end

  @impl Plug
  def call(%Plug.Conn{method: "GET", request_path: "/health"} = conn, _opts) do
    json(conn, 200, %{ok: true})
  end

  def call(%Plug.Conn{method: "POST", request_path: "/v1/cli"} = conn, opts) do
    with {:ok, body, conn} <-
           read_body(conn, length: @max_body_bytes, read_length: @max_body_bytes),
         {:ok, %{"args" => args}} <- Jason.decode(body),
         :ok <- validate_args(args) do
      execute(conn, args, opts)
    else
      _ -> json(conn, 400, %{ok: false, error: "invalid request"})
    end
  end

  def call(conn, _opts), do: json(conn, 404, %{ok: false, error: "not found"})

  defp validate_args(args) when is_list(args) and length(args) <= @max_args do
    if Enum.all?(args, &(is_binary(&1) and byte_size(&1) <= @max_arg_bytes)),
      do: :ok,
      else: :error
  end

  defp validate_args(_args), do: :error

  defp execute(conn, args, opts) do
    task = Task.Supervisor.async_nolink(opts.supervisor, fn -> opts.runner.(args) end)

    case Task.yield(task, opts.timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, output}} -> json(conn, 200, Map.put(output, :ok, true))
      {:ok, {:error, error}} -> json(conn, 422, %{ok: false, error: inspect_error(error)})
      {:exit, _reason} -> json(conn, 500, %{ok: false, error: "request failed"})
      nil -> json(conn, 504, %{ok: false, error: "request timed out"})
    end
  end

  defp inspect_error(:usage), do: "usage: " <> SpruceGoose.CLI.Command.usage()
  defp inspect_error(error) when is_binary(error), do: error
  defp inspect_error(error) when is_exception(error), do: Exception.message(error)
  defp inspect_error(error), do: inspect(error)

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
