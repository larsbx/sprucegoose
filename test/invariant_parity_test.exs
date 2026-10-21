defmodule SpruceGoose.InvariantParityTest do
  @moduledoc """
  Every immutability or identity invariant the database enforces with a
  trigger must also be a property of the domain: the resource that owns the
  table exposes no action that could violate it. This test is what makes
  "PostgreSQL is the second enforcer, not the only one" checkable.
  """
  use ExUnit.Case, async: true

  @migrations Path.wildcard("priv/repo/migrations/*.exs")
              |> Enum.map(&File.read!/1)
              |> Enum.join("\n")

  # table => {resource, actions that may update, actions that may destroy}
  @owned %{
    "deployment_releases" => {SpruceGoose.Deployment.Release, [], []},
    "deployment_authorizations" => {SpruceGoose.Deployment.Authorization, [], []},
    "deployment_authorization_revocations" => {SpruceGoose.Deployment.Revocation, [], []},
    "deployments" => {SpruceGoose.Deployment.Record, [:project], []},
    "deployment_operations" =>
      {SpruceGoose.Deployment.Operation, [:start, :complete, :observe, :abandon, :withdraw], []},
    "derivation_permits" => {SpruceGoose.Derivations.Permit, [], []},
    "derivation_outcome_receipts" => {SpruceGoose.Derivations.OutcomeReceipt, [], []},
    "runtime_shadow_snapshots" => {SpruceGoose.Runtime.ShadowSnapshot, [], []}
  }

  # Tables with an immutability trigger and no Ash resource: their only writer
  # is a port whose contract has no update or delete.
  @port_owned %{
    "certified_events" => SpruceGoose.Kernel.EventLedger,
    "certified_event_rekeys" => SpruceGoose.Kernel.EventLedger
  }

  test "every immutability trigger has a resource that exposes no violating action" do
    for {table, {resource, updates, destroys}} <- @owned do
      assert @migrations =~ ~r/ON #{table}\b/, "#{table} has no trigger in the migrations"

      actions = Ash.Resource.Info.actions(resource)
      update_names = for %{type: :update, name: name} <- actions, do: name
      destroy_names = for %{type: :destroy, name: name} <- actions, do: name

      assert Enum.sort(update_names) == Enum.sort(updates),
             "#{inspect(resource)} exposes update actions #{inspect(update_names)}; the database allows only #{inspect(updates)}"

      assert Enum.sort(destroy_names) == Enum.sort(destroys),
             "#{inspect(resource)} exposes destroy actions #{inspect(destroy_names)}"
    end
  end

  test "frozen identity columns are not writable by any update action" do
    frozen = %{
      SpruceGoose.Deployment.Record => [:deployment_id, :release_id, :project_id, :environment],
      SpruceGoose.Deployment.Operation => [
        :operation_id,
        :authorization_id,
        :action,
        :deployment_id
      ]
    }

    for {resource, columns} <- frozen,
        %{type: :update, name: name, accept: accept} <- Ash.Resource.Info.actions(resource),
        column <- columns do
      refute column in accept, "#{inspect(resource)}.#{name} accepts frozen column #{column}"
    end
  end

  test "port-owned immutable tables have no update or delete in their contract" do
    for {table, port} <- @port_owned do
      assert @migrations =~ ~r/ON #{table}\b/
      callbacks = port.behaviour_info(:callbacks) |> Keyword.keys()
      assert Enum.sort(callbacks) == [:append, :head, :read, :streams, :verify]
    end
  end
end
