defmodule SpruceGoose.Web.ActorPlug do
  @moduledoc """
  Map an authenticated MCP client to a registered actor.

  `BearerPlug` has already established *which OAuth client* is calling; this
  turns that into *which actor*, by matching the client name against the actor
  registry. AshAi reads the actor straight off the connection
  (`Ash.PlugHelpers.get_actor/1`), so the read-only tools inherit exactly the
  same project scoping the CLI gets, with no change to the tool list.

  Unlike the CLI's `--as`, this side is genuinely authenticated: the caller had
  to present a valid bearer token to reach here. A client with no matching
  actor is refused rather than defaulted — an unregistered caller is not an
  anonymous one, it is one nobody granted anything.
  """

  @behaviour Plug

  import Plug.Conn

  require Ash.Query

  alias SpruceGoose.Actors.Actor

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case client_name(conn) do
      nil -> refuse(conn, "the bearer token names no client")
      name -> assign_actor(conn, name)
    end
  end

  defp assign_actor(conn, name) do
    Actor
    |> Ash.Query.filter_input(name: name)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, actor} when not is_nil(actor) ->
        if Actor.active?(actor) do
          Ash.PlugHelpers.set_actor(conn, actor)
        else
          refuse(conn, "actor #{name} is disabled")
        end

      _ ->
        refuse(conn, "no actor is registered as #{inspect(name)}")
    end
  end

  # The client name is where the OAuth registration and the actor registry meet.
  # Both are administered by hand on this fleet, so the join is a name match.
  defp client_name(conn) do
    case conn.assigns do
      %{oauth2_client: %{client_name: name}} when is_binary(name) -> name
      _ -> subject_name(conn)
    end
  end

  defp subject_name(conn) do
    case Ash.PlugHelpers.get_actor(conn) do
      %{client_name: name} when is_binary(name) -> name
      _ -> nil
    end
  end

  defp refuse(conn, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{ok: false, error: reason}))
    |> halt()
  end
end
