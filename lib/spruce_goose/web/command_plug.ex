defmodule SpruceGoose.Web.CommandPlug do
  @moduledoc """
  The authenticated write surface: `POST /commands` with `{"argv": [...]}`.

  Runs behind the same bearer, scope, and actor-binding pipeline as the MCP
  reads, so the actor is the verified OAuth client's bound actor and nothing
  else. A caller may not name an actor: `--as` is refused outright, because
  on this path identity is established, not declared. Every certified event
  the command produces records the binding as `token`.
  """

  @behaviour Plug

  import Plug.Conn

  alias SpruceGoose.CLI.{Command, Executor}

  @max_body 65_536

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, actor} <- actor(conn),
         {:ok, argv} <- argv(conn),
         :ok <- refuse_declared_actor(argv),
         {:ok, command} <- parse(argv) do
      case Executor.run_authenticated(command, actor) do
        {:ok, output} -> respond(conn, 200, Map.put(output, :ok, true))
        {:error, error} -> respond(conn, 422, %{ok: false, error: message(error)})
      end
    else
      {:refuse, status, reason} -> respond(conn, status, %{ok: false, error: reason})
    end
  end

  defp actor(conn) do
    case Ash.PlugHelpers.get_actor(conn) do
      %SpruceGoose.Actors.Actor{} = actor -> {:ok, actor}
      _ -> {:refuse, 403, "no authenticated actor on this request"}
    end
  end

  defp argv(%{body_params: %{"argv" => argv}}) when is_list(argv), do: validate_argv(argv)

  defp argv(conn) do
    with {:ok, body, _conn} <- read_body(conn, length: @max_body),
         {:ok, %{"argv" => argv}} when is_list(argv) <- Jason.decode(body) do
      validate_argv(argv)
    else
      _ -> {:refuse, 400, "body must be a JSON object with an argv list of strings"}
    end
  end

  defp validate_argv(argv) do
    if argv != [] and Enum.all?(argv, &is_binary/1),
      do: {:ok, argv},
      else: {:refuse, 400, "argv must be a non-empty list of strings"}
  end

  defp refuse_declared_actor(argv) do
    case Command.extract_actor(argv) do
      {nil, _} ->
        :ok

      {_name, _} ->
        {:refuse, 400, "the authenticated client is the actor; --as is not accepted here"}
    end
  end

  defp parse(argv) do
    case Command.parse(argv) do
      {:ok, command} -> {:ok, command}
      {:error, :usage} -> {:refuse, 400, "usage: " <> Command.usage()}
      {:error, reason} -> {:refuse, 400, message(reason)}
    end
  end

  defp respond(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  defp message(error) when is_binary(error), do: error
  defp message(error) when is_exception(error), do: Exception.message(error)
  defp message(error), do: inspect(error)
end
