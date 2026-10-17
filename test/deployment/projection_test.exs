defmodule SpruceGoose.Deployment.ProjectionTest do
  use ExUnit.Case, async: true

  alias SpruceGoose.Deployment.Projection
  alias SpruceGoose.Kernel.CertifiedEvent

  @roots Map.new(
           ~w(ontology schema norm policy grant_epoch agent_charter interpreter evidence_policy),
           &{&1, "sha256:" <> String.duplicate("e", 64)}
         )
  @release %{
    "forge_instance" => "forgejo-mama",
    "repository" => "root/sprucegoose",
    "source_commit" => String.duplicate("a", 40),
    "pipeline_number" => 7,
    "pipeline_digest" => String.duplicate("c", 64),
    "artifacts" => %{"archive" => "sha256:" <> String.duplicate("1", 64)}
  }

  defp created(overrides \\ %{}) do
    Map.merge(
      %{
        "deployment_id" => "dpl-1",
        "project" => "sprucegoose",
        "environment" => "staging",
        "release" => @release,
        "release_id" => "rel-x",
        "requires_routing" => false
      },
      overrides
    )
  end

  # Chains events by hand exactly as the ledger writer does: each payload names
  # the identity of the event before it.
  defp chain(steps) do
    steps
    |> Enum.reduce({[], nil}, fn {type, payload}, {events, previous} ->
      {:ok, event} =
        CertifiedEvent.new(%{
          stream: "deployment:dpl-1",
          event_type: type,
          idempotency_key: "#{type}:#{length(events)}",
          payload: Map.merge(payload, %{"schema" => Projection.schema(), "previous" => previous}),
          roots: @roots
        })

      {[event | events], event.identity.digest}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp transition(state), do: {"DeploymentTransitioned", %{"state" => state}}

  test "a linked, lawful history projects to a ready deployment with attributed operations" do
    events =
      chain([
        {"DeploymentCreated", created()},
        transition("building"),
        transition("staged"),
        {"DeploymentOperationRequested",
         %{"operation_id" => "dpo-1", "action" => "execute_deploy", "authorization_id" => "dpa-1"}},
        transition("deploying"),
        {"DeploymentOperationStarted", %{"operation_id" => "dpo-1", "executor_id" => "host"}},
        {"DeploymentOperationObserved", %{"operation_id" => "dpo-1", "status" => "in_progress"}},
        {"DeploymentOperationCompleted",
         %{"operation_id" => "dpo-1", "outcome" => "succeeded", "source" => "observation"}},
        transition("verifying"),
        {"DeploymentHealthObserved", %{"status" => "healthy", "detail" => "probe ok"}},
        transition("ready")
      ])

    assert {:ok, projection} = Projection.reduce(events)
    assert projection.state == :ready
    assert projection.environment == :staging
    assert projection.health == %{status: :healthy, detail: "probe ok"}
    assert projection.event_count == 11
    assert projection.last_identity == List.last(events).identity.digest

    assert %{
             action: :execute_deploy,
             phase: :completed,
             outcome: :succeeded,
             source: "observation",
             observations: ["in_progress"]
           } = projection.operations["dpo-1"]
  end

  test "a broken link, a gap, or a fork is refused at the first bad event" do
    [a, b, c] =
      chain([{"DeploymentCreated", created()}, transition("building"), transition("staged")])

    assert {:error, {:invalid_event, 2, :broken_chain}} = Projection.reduce([a, c])
    assert {:error, {:invalid_event, 1, :broken_chain}} = Projection.reduce([b])
    assert {:ok, _} = Projection.reduce([a, b, c])

    [_, fork] = chain([{"DeploymentCreated", created()}, transition("cancelled")])
    assert {:error, {:invalid_event, 3, :broken_chain}} = Projection.reduce([a, b, fork])
  end

  test "illegal lifecycle steps, out-of-order operation phases, and duplicates fail closed" do
    assert {:error, {:invalid_event, 2, :invalid_transition}} =
             [{"DeploymentCreated", created()}, transition("ready")]
             |> chain()
             |> Projection.reduce()

    assert {:error, {:invalid_event, 2, :unknown_operation}} =
             [
               {"DeploymentCreated", created()},
               {"DeploymentOperationStarted", %{"operation_id" => "dpo-9"}}
             ]
             |> chain()
             |> Projection.reduce()

    requested =
      {"DeploymentOperationRequested", %{"operation_id" => "dpo-1", "action" => "execute_deploy"}}

    assert {:error, {:invalid_event, 3, :operation_out_of_order}} =
             [
               {"DeploymentCreated", created()},
               requested,
               {"DeploymentOperationCompleted",
                %{"operation_id" => "dpo-1", "outcome" => "succeeded"}}
             ]
             |> chain()
             |> Projection.reduce()

    assert {:error, {:invalid_event, 3, :duplicate_operation}} =
             [{"DeploymentCreated", created()}, requested, requested]
             |> chain()
             |> Projection.reduce()

    assert {:error, {:invalid_event, 2, :duplicate_creation}} =
             [{"DeploymentCreated", created()}, {"DeploymentCreated", created()}]
             |> chain()
             |> Projection.reduce()

    assert {:error, {:invalid_event, 1, :uncreated}} =
             [transition("building")] |> chain() |> Projection.reduce()

    assert {:error, {:invalid_event, 2, :unknown_action}} =
             [
               {"DeploymentCreated", created()},
               {"DeploymentOperationRequested", %{"operation_id" => "dpo-1", "action" => "sudo"}}
             ]
             |> chain()
             |> Projection.reduce()
  end

  test "creation requires a valid typed release identity and a known environment" do
    assert {:error, {:invalid_event, 1, :malformed_creation}} =
             [{"DeploymentCreated", created(%{"environment" => "prod"})}]
             |> chain()
             |> Projection.reduce()

    assert {:error, {:invalid_event, 1, :malformed_creation}} =
             [{"DeploymentCreated", created(%{"release" => Map.put(@release, "artifacts", %{})})}]
             |> chain()
             |> Projection.reduce()
  end
end
