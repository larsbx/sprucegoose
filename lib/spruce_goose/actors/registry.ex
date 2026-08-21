defmodule SpruceGoose.Actors.Registry do
  @moduledoc """
  The CLI's view of the actor registry: who exists, what they hold, and who may
  change that.

  Registry writes are gated here rather than by Ash policies, because the
  registry is what every policy check reads — see `SpruceGoose.Actors`. The gate
  is `admin` at global scope, with one exception.

  ## Genesis

  While the registry is **empty** there is no admin to authorize the first one,
  so `add/2` is permitted and must create a `:human` holding `admin` at `*`.
  The response says so loudly. This is the same reasoning that keeps vault reads
  ungated: a control that can lock you out of fixing it is not a control, it is
  a trap. Once one actor exists, genesis is closed and `admin` is required.
  """

  require Ash.Query

  alias SpruceGoose.Actors.{Actor, Grant, Scope}
  alias SpruceGoose.Repo
  alias SpruceGoose.Workflows.Project

  @admin_scope "*"
  @registry_write_lock "sprucegoose:actor-registry-write"

  # -- actors ----------------------------------------------------------------

  def add(attrs, acting) do
    serialized_registry_write(fn ->
      result =
        case genesis?() do
          true ->
            genesis_add(attrs)

          false ->
            with {:ok, current_admin} <- require_current_admin(acting),
                 {:ok, actor, notifications} <- create_actor(attrs, current_admin.name) do
              {:ok, Map.put(actor_json(actor), :grants, []), notifications}
            end
        end

      rollback_registry_error(result)
    end)
    |> case do
      {:ok, {:ok, result, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, result}

      {:error, error} ->
        {:error, error}
    end
  end

  def list(kind, acting) do
    with :ok <- require_admin(acting),
         {:ok, actors} <- read_actors(kind) do
      {:ok, %{actors: actors |> Enum.sort_by(& &1.name) |> Enum.map(&actor_json/1)}}
    end
  end

  def show(name, acting) do
    with :ok <- require_admin(acting),
         {:ok, actor} <- fetch(name) do
      {:ok, Map.put(actor_json(actor), :grants, Scope.summary(actor))}
    end
  end

  def disable(name, reason, acting) do
    registry_write(fn ->
      with {:ok, current_admin} <- require_current_admin(acting),
           :ok <- require_reason(reason),
           {:ok, actor} <- fetch(name),
           :ok <- refuse_self(actor, current_admin, "disable"),
           {:ok, actor, notifications} <-
             Ash.update(actor, %{disabled_reason: reason},
               action: :disable,
               authorize?: false,
               return_notifications?: true
             ) do
        {:ok, actor_json(actor), notifications}
      end
    end)
  end

  def enable(name, acting) do
    registry_write(fn ->
      with {:ok, _current_admin} <- require_current_admin(acting),
           {:ok, actor} <- fetch(name),
           {:ok, actor, notifications} <-
             Ash.update(actor, %{},
               action: :enable,
               authorize?: false,
               return_notifications?: true
             ) do
        {:ok, actor_json(actor), notifications}
      end
    end)
  end

  # -- grants ----------------------------------------------------------------

  def grant(name, role, scope, acting) do
    registry_write(fn ->
      with {:ok, current_admin} <- require_current_admin(acting),
           {:ok, role} <- parse_role(role),
           :ok <- validate_scope(scope),
           {:ok, actor} <- fetch(name),
           {:ok, _grant, notifications} <-
             Ash.create(
               Grant,
               %{actor_id: actor.id, role: role, scope: scope, granted_by: current_admin.name},
               authorize?: false,
               return_notifications?: true
             ) do
        {:ok, Map.put(actor_json(actor), :grants, Scope.summary(actor)), notifications}
      end
    end)
  end

  def revoke(name, role, scope, acting) do
    registry_write(fn ->
      with {:ok, _current_admin} <- require_current_admin(acting),
           {:ok, role} <- parse_role(role),
           {:ok, actor} <- fetch(name),
           {:ok, grant} <- fetch_grant(actor, role, scope),
           :ok <- refuse_last_admin(actor, grant),
           {:ok, notifications} <- destroy(grant) do
        {:ok, Map.put(actor_json(actor), :grants, Scope.summary(actor)), notifications}
      end
    end)
  end

  def grants(name, role, acting) do
    with :ok <- require_admin(acting),
         {:ok, grants} <- read_grants(name, role) do
      {:ok, %{grants: grants}}
    end
  end

  # -- whoami ----------------------------------------------------------------

  # Deliberately ungated: an actor may always see its own name and grants. Any
  # other rule makes "why was I refused?" unanswerable from the CLI.
  def whoami(acting) do
    {:ok, Map.put(actor_json(acting), :grants, Scope.summary(acting))}
  end

  # -- gates -----------------------------------------------------------------

  defp registry_write(fun) do
    serialized_registry_write(fn -> fun.() |> rollback_registry_error() end)
    |> case do
      {:ok, {:ok, result, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, result}

      {:error, error} ->
        {:error, error}
    end
  end

  defp serialized_registry_write(fun) do
    # AUTHORIZATION: registry authorization is re-read and enforced inside this serialized transaction.
    Repo.transaction(fn ->
      # All actor/grant mutations share this transaction-scoped lock. Re-reading
      # the acting administrator after the lock makes authority stable through
      # commit: disable/revoke cannot interleave after the authorization check.
      # AUTHORIZATION: this SQL only serializes the gated registry decision; it accesses no domain rows.
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT pg_advisory_xact_lock(hashtext($1))",
        [@registry_write_lock]
      )

      fun.()
    end)
  end

  defp rollback_registry_error({:error, error}), do: Repo.rollback(error)
  defp rollback_registry_error(success), do: success

  defp require_current_admin(%{name: name}) when is_binary(name) do
    with {:ok, current} <- fetch(name),
         :ok <- require_admin(current) do
      {:ok, current}
    end
  end

  defp require_current_admin(_acting),
    do: {:error, "registry changes require an actor: pass --as NAME"}

  defp genesis?, do: Ash.count!(Actor, authorize?: false) == 0

  defp genesis_add(attrs) do
    with :ok <- require_expected_genesis(attrs) do
      if Map.get(attrs, :kind) == :human do
        with {:ok, actor, actor_notifications} <- create_actor(attrs, "genesis"),
             {:ok, grant_notifications} <- grant_all(actor),
             {:ok, reloaded} <- fetch(actor.name) do
          {:ok,
           reloaded
           |> actor_json()
           |> Map.merge(%{
             grants: Scope.summary(reloaded),
             genesis: true,
             note:
               "registry was empty, so #{reloaded.name} was created as the genesis actor " <>
                 "holding every role at #{@admin_scope}. Every later actor requires an " <>
                 "admin to create it, and should be granted only what it needs."
           }), actor_notifications ++ grant_notifications}
        end
      else
        {:error,
         "the first actor must be --kind human: an empty registry has nobody to hold " <>
           "an agent accountable"}
      end
    end
  end

  defp require_expected_genesis(%{name: name}) do
    case Application.get_env(:spruce_goose, :expected_genesis_actor) do
      nil ->
        :ok

      ^name ->
        :ok

      expected ->
        {:error, "expected Genesis actor #{expected}; refusing first actor #{name}"}
    end
  end

  defp require_expected_genesis(_attrs), do: :ok

  # Every role, not just admin. Admin can grant itself anything unilaterally, so
  # withholding the rest at genesis is ceremony rather than a control — it only
  # buys the first operator five commands before they can do any work.
  defp grant_all(actor) do
    Enum.reduce_while(SpruceGoose.Actors.Role.values(), {:ok, []}, fn role,
                                                                      {:ok, notifications} ->
      case Ash.create(
             Grant,
             %{actor_id: actor.id, role: role, scope: @admin_scope, granted_by: "genesis"},
             authorize?: false,
             return_notifications?: true
           ) do
        {:ok, _grant, created_notifications} ->
          {:cont, {:ok, notifications ++ created_notifications}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp create_actor(attrs, created_by) do
    Ash.create(Actor, Map.put(attrs, :created_by, created_by),
      authorize?: false,
      return_notifications?: true
    )
  end

  defp require_admin(acting) do
    cond do
      not is_struct(acting) ->
        {:error, "registry changes require an actor: pass --as NAME"}

      not Actor.active?(acting) ->
        {:error, "actor #{acting.name} is disabled"}

      Scope.holds?(acting, :admin, :global) ->
        :ok

      true ->
        {:error,
         "actor #{acting.name} does not hold admin at #{@admin_scope}; " <>
           "the registry is fleet-wide, so managing it is too"}
    end
  end

  # An admin that can strip its own last admin grant can lock the fleet out of
  # its own registry. Refusing here is cheaper than a recovery procedure.
  defp refuse_last_admin(actor, %{role: :admin, scope: @admin_scope}) do
    remaining =
      Grant
      |> Ash.Query.filter_input(role: :admin, scope: @admin_scope)
      |> Ash.Query.filter(Ash.Expr.expr(is_nil(actor.disabled_at)))
      |> Ash.read!(authorize?: false)
      |> Enum.reject(&(&1.actor_id == actor.id))

    if remaining == [] do
      {:error,
       "refusing to revoke the last active global admin grant (the last global admin " <>
         "capable of recovery); enable or grant admin to another actor first"}
    else
      :ok
    end
  end

  defp refuse_last_admin(_actor, _grant), do: :ok

  defp refuse_self(%{id: id}, %{id: id}, verb),
    do: {:error, "refusing to #{verb} the acting actor; have another admin do it"}

  defp refuse_self(_actor, _acting, _verb), do: :ok

  defp require_reason(reason) when is_binary(reason) do
    if String.trim(reason) == "", do: {:error, "a reason is required"}, else: :ok
  end

  defp require_reason(_reason), do: {:error, "a reason is required"}

  defp parse_role(role) when is_binary(role) do
    if role in valid_roles() do
      {:ok, String.to_existing_atom(role)}
    else
      {:error, "role must be one of #{Enum.join(valid_roles(), ", ")}"}
    end
  end

  defp parse_role(_role), do: {:error, "--role is required"}

  def valid_roles, do: Enum.map(SpruceGoose.Actors.Role.values(), &to_string/1)

  def valid_kinds, do: ~w(human agent system)

  # A grant naming a project that does not exist is a permission nobody can use
  # and nobody will notice is wrong.
  defp validate_scope(scope) do
    case Grant.parse_scope(scope) do
      {:ok, :global} ->
        :ok

      {:ok, {:project, key}} ->
        case Ash.read_one(Ash.Query.filter_input(Project, key: key), authorize?: false) do
          {:ok, nil} -> {:error, "no project #{inspect(key)} to scope this grant to"}
          {:ok, _project} -> :ok
          {:error, error} -> {:error, Exception.message(error)}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  # -- plumbing --------------------------------------------------------------

  defp fetch(name) do
    case Ash.read_one(Ash.Query.filter_input(Actor, name: name), authorize?: false) do
      {:ok, nil} -> {:error, "unknown actor #{inspect(name)}"}
      result -> result
    end
  end

  defp fetch_grant(actor, role, scope) do
    Grant
    |> Ash.Query.filter_input(actor_id: actor.id, role: role, scope: scope)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, "#{actor.name} does not hold #{role} at #{scope}"}
      result -> result
    end
  end

  defp read_actors(nil), do: Ash.read(Actor, authorize?: false)

  defp read_actors(kind) when kind in ["human", "agent", "system"],
    do: Ash.read(Ash.Query.filter_input(Actor, kind: kind), authorize?: false)

  defp read_actors(_kind), do: {:error, "--kind must be one of #{Enum.join(valid_kinds(), ", ")}"}

  defp read_grants(name, role) do
    with {:ok, filter} <- grant_filter(name, role),
         {:ok, grants} <- Ash.read(Ash.Query.filter_input(Grant, filter), authorize?: false),
         {:ok, actors} <- Ash.read(Actor, authorize?: false) do
      names = Map.new(actors, &{&1.id, &1.name})

      {:ok,
       grants
       |> Enum.map(
         &%{
           actor: Map.get(names, &1.actor_id),
           role: &1.role,
           scope: &1.scope,
           granted_by: &1.granted_by,
           granted_at: &1.granted_at
         }
       )
       |> Enum.sort_by(&{&1.actor, to_string(&1.role), &1.scope})}
    end
  end

  defp grant_filter(name, role) do
    with {:ok, filter} <- actor_filter(name) do
      case role do
        nil -> {:ok, filter}
        role -> with {:ok, role} <- parse_role(role), do: {:ok, Keyword.put(filter, :role, role)}
      end
    end
  end

  defp actor_filter(nil), do: {:ok, []}

  defp actor_filter(name) do
    with {:ok, actor} <- fetch(name), do: {:ok, [actor_id: actor.id]}
  end

  defp destroy(record) do
    Ash.destroy(record, authorize?: false, return_notifications?: true)
  end

  defp actor_json(actor) do
    %{
      actor: actor.name,
      kind: actor.kind,
      description: actor.description,
      disabled_at: actor.disabled_at,
      disabled_reason: actor.disabled_reason,
      created_by: actor.created_by
    }
  end
end
