ExUnit.start(exclude: [:separate_sessions])

defmodule SpruceGoose.SandboxMode do
  @moduledoc """
  Set the sandbox mode, but only where there is a sandbox.

  `SPRUCE_GOOSE_TEST_DOGFOOD=true` switches the pool to
  `DBConnection.ConnectionPool` so the `:separate_sessions` group can hold
  genuinely separate database sessions. Every `Sandbox.mode/2` call then raises
  — including the one at the top of this file, which aborted the whole run
  before a single test loaded and made the only documented way to run that
  group unusable.

  Under the real pool the tests already have what `:auto` was asking for, so
  there is nothing to do.
  """

  def set(mode) do
    if SpruceGoose.Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox do
      Ecto.Adapters.SQL.Sandbox.mode(SpruceGoose.Repo, mode)
    end

    :ok
  end
end

SpruceGoose.SandboxMode.set(:manual)

defmodule SpruceGoose.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias SpruceGoose.Repo
      import Ecto.Query
    end
  end

  setup tags do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(SpruceGoose.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    seed_system_actor()
    :ok
  end

  @doc """
  Seed the actor `config/test.exs` names as `:default_actor`, with a global
  admin grant.

  Every `Executor.run/1` in the suite resolves to this actor, so policies run on
  every call rather than being bypassed — the suite exercises the authorized
  path, it just does so as a fully privileged party. Tests about *permissions*
  create their own restricted actors and name them with `Executor.run/2`.

  Seeded per test because the sandbox rolls each one back.
  """
  def seed_system_actor do
    name = Application.fetch_env!(:spruce_goose, :default_actor)

    {:ok, actor} =
      Ash.create(
        SpruceGoose.Actors.Actor,
        %{name: name, kind: :system, created_by: "test-helper"},
        authorize?: false
      )

    {:ok, _grant} =
      Ash.create(
        SpruceGoose.Actors.Grant,
        %{actor_id: actor.id, role: :admin, scope: "*", granted_by: "test-helper"},
        authorize?: false
      )

    # Admin manages the registry; it is not a superuser over the work itself.
    # The suite acts across every role, so grant each one globally.
    for role <- [
          :reader,
          :operator,
          :derivation_executor,
          :artifact_verifier,
          :proposer,
          :approver,
          :author
        ] do
      {:ok, _} =
        Ash.create(
          SpruceGoose.Actors.Grant,
          %{actor_id: actor.id, role: role, scope: "*", granted_by: "test-helper"},
          authorize?: false
        )
    end

    actor
  end
end
