defmodule SpruceGoose.Actors.Resolver.Declared do
  @moduledoc """
  Resolve the actor from the name the caller declared.

  Precedence: the `--as` name, then the `SPRUCE_GOOSE_ACTOR` environment
  variable, then the `:default_actor` application setting. The env var is read
  **service-side** — it describes the environment the CLI service was started
  in, not the caller's shell — so it is a convenience for a single-agent
  deployment and `--as` is the real mechanism.

  Both fallbacks are unset by default, so a deployment that configures neither
  refuses every request that does not name its actor. Configuring one is an
  operator saying "this service acts as X unless told otherwise", which is a
  claim worth being able to make explicitly rather than by accident.

  Lookups run with `authorize?: false` on purpose. This adapter is what every
  policy check reads; making it subject to those policies would make
  authorization depend on being authorized.
  """

  @behaviour SpruceGoose.Actors.Resolver

  require Ash.Query

  alias SpruceGoose.Actors.Actor

  @impl true
  def resolve(name) do
    case declared(name) do
      nil ->
        {:error,
         "no actor: pass --as NAME or set SPRUCE_GOOSE_ACTOR. " <>
           "Run `sprucegoose actor list` to see who is registered"}

      name ->
        lookup(name)
    end
  end

  defp declared(name) when is_binary(name) do
    case String.trim(name) do
      "" -> from_env()
      trimmed -> trimmed
    end
  end

  defp declared(_name), do: from_env()

  defp from_env do
    case System.get_env("SPRUCE_GOOSE_ACTOR", "") |> String.trim() do
      "" -> configured()
      name -> name
    end
  end

  defp configured do
    case Application.get_env(:spruce_goose, :default_actor) do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp lookup(name) do
    Actor
    |> Ash.Query.filter_input(name: name)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} ->
        {:error, "unknown actor #{inspect(name)}; register it with `sprucegoose actor add`"}

      {:ok, actor} ->
        if Actor.active?(actor) do
          {:ok, actor}
        else
          {:error, "actor #{name} is disabled: #{actor.disabled_reason}"}
        end

      {:error, error} ->
        {:error, "cannot read the actor registry: #{Exception.message(error)}"}
    end
  end
end
