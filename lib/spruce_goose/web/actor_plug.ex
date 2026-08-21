defmodule SpruceGoose.Web.ActorPlug do
  @moduledoc """
  Map an authenticated MCP OAuth client to a registered actor through an
  administrator-governed immutable-ID binding.

  `BearerPlug` establishes which OAuth client is calling. This plug resolves
  that client's immutable ID through `:oauth_client_actor_bindings`, whose
  values are immutable actor IDs. Registration metadata such as `client_name`
  is never an authority input. An unbound client is refused.
  """

  @behaviour Plug

  import Plug.Conn

  require Ash.Query

  alias SpruceGoose.Actors.Actor

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with client_id when is_binary(client_id) <- client_id(conn),
         {:ok, actor_id} <- actor_binding(client_id) do
      assign_actor(conn, client_id, actor_id)
    else
      nil -> refuse(conn, "the bearer token has no verified OAuth client ID")
      :error -> refuse(conn, "no actor binding exists for this OAuth client ID")
    end
  end

  defp assign_actor(conn, client_id, actor_id) do
    Actor
    |> Ash.Query.filter_input(id: actor_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, actor} when not is_nil(actor) ->
        if Actor.active?(actor) do
          Ash.PlugHelpers.set_actor(conn, actor)
        else
          refuse(conn, "the actor bound to OAuth client #{client_id} is disabled")
        end

      _ ->
        refuse(conn, "the actor bound to OAuth client #{client_id} does not exist")
    end
  end

  defp actor_binding(client_id) do
    :spruce_goose
    |> Application.get_env(:oauth_client_actor_bindings, %{})
    |> Map.fetch(client_id)
  end

  defp client_id(conn) do
    case conn.assigns do
      %{oauth_claims: %{"client_id" => id}} when is_binary(id) and id != "" -> id
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
