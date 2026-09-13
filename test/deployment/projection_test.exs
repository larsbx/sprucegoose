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
    assert projection.health == %{status: :healthy, detail: "probe ok", source: nil}
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

    staged = [{"DeploymentCreated", created()}, transition("building"), transition("staged")]

    assert {:error, {:invalid_event, 5, :operation_out_of_order}} =
             (staged ++
                [
                  requested,
                  {"DeploymentOperationCompleted",
                   %{"operation_id" => "dpo-1", "outcome" => "succeeded"}}
                ])
             |> chain()
             |> Projection.reduce()

    assert {:error, {:invalid_event, 5, :duplicate_operation}} =
             (staged ++ [requested, requested]) |> chain() |> Projection.reduce()

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

  test "replay admits each request only in the states the facade admits it" do
    created = {"DeploymentCreated", created()}

    requested =
      {"DeploymentOperationRequested", %{"operation_id" => "dpo-1", "action" => "execute_deploy"}}

    # Health only while verifying; cancellation only where the contract allows; rollback only from its sources.
    assert {:error, {:invalid_event, 2, :not_admitted}} =
             [created, {"DeploymentHealthObserved", %{"status" => "healthy"}}]
             |> chain()
             |> Projection.reduce()

    assert {:error, {:invalid_event, 6, :not_admitted}} =
             [
               created,
               transition("building"),
               transition("staged"),
               requested,
               transition("deploying"),
               {"DeploymentCancellationRequested", %{"reason" => "late"}}
             ]
             |> chain()
             |> Projection.reduce()

    assert {:error, {:invalid_event, 2, :not_admitted}} =
             [created, {"DeploymentRollbackRequested", %{"target_deployment_id" => "dpl-0"}}]
             |> chain()
             |> Projection.reduce()

    # A deploy may only be requested from staged, and never while another operation is open.
    assert {:error, {:invalid_event, 2, :not_admitted}} =
             [created, requested] |> chain() |> Projection.reduce()

    # A second operation while one is open: only a reclaim can be admitted by
    # state while another reclaim is open, so that is where the guard bites.
    reclaim_1 =
      {"DeploymentOperationRequested",
       %{"operation_id" => "dpo-2", "action" => "execute_reclaim"}}

    reclaim_2 =
      {"DeploymentOperationRequested",
       %{"operation_id" => "dpo-3", "action" => "execute_reclaim"}}

    assert {:error, {:invalid_event, 4, :operation_in_flight}} =
             [
               {"DeploymentCreated", created(%{"environment" => "preview"})},
               transition("cancelled"),
               reclaim_1,
               reclaim_2
             ]
             |> chain()
             |> Projection.reduce()

    # Reclaim only for a terminal preview.
    reclaim =
      {"DeploymentOperationRequested",
       %{"operation_id" => "dpo-3", "action" => "execute_reclaim"}}

    assert {:error, {:invalid_event, 3, :not_admitted}} =
             [created, transition("cancelled"), reclaim] |> chain() |> Projection.reduce()

    assert {:ok, _} =
             [
               {"DeploymentCreated", created(%{"environment" => "preview"})},
               transition("cancelled"),
               reclaim
             ]
             |> chain()
             |> Projection.reduce()
  end

  test "the live pointer moves only through activation and supersession, and only when admitted" do
    to_ready = [
      {"DeploymentCreated", created()},
      transition("building"),
      transition("staged"),
      {"DeploymentOperationRequested",
       %{"operation_id" => "dpo-1", "action" => "execute_deploy"}},
      transition("deploying"),
      {"DeploymentOperationStarted", %{"operation_id" => "dpo-1"}},
      {"DeploymentOperationCompleted", %{"operation_id" => "dpo-1", "outcome" => "succeeded"}},
      transition("verifying"),
      {"DeploymentHealthObserved", %{"status" => "healthy", "source" => "adapter"}},
      transition("ready")
    ]

    assert {:ok, projection} = to_ready |> chain() |> Projection.reduce()
    refute projection.active
    assert projection.health.source == "adapter"

    activated = {"DeploymentActivated", %{"cause" => "ready", "supersedes" => nil}}
    superseded = {"DeploymentSuperseded", %{"by" => "dpl-2", "cause" => "ready"}}

    assert {:ok, %{active: true, superseded_by: nil}} =
             (to_ready ++ [activated]) |> chain() |> Projection.reduce()

    assert {:ok, %{active: false, superseded_by: "dpl-2"}} =
             (to_ready ++ [activated, superseded]) |> chain() |> Projection.reduce()

    assert {:error, {:invalid_event, 2, :not_admitted}} =
             [{"DeploymentCreated", created()}, activated] |> chain() |> Projection.reduce()

    assert {:error, {:invalid_event, 11, :not_active}} =
             (to_ready ++ [superseded]) |> chain() |> Projection.reduce()
  end

  test "building is transient: it admits only the step to staged" do
    created = {"DeploymentCreated", created()}

    assert {:error, {:invalid_event, 3, :transient_state_escaped}} =
             [created, transition("building"), transition("cancelled")]
             |> chain()
             |> Projection.reduce()

    assert {:error, {:invalid_event, 3, :transient_state_escaped}} =
             [
               created,
               transition("building"),
               {"DeploymentHealthObserved", %{"status" => "healthy"}}
             ]
             |> chain()
             |> Projection.reduce()

    assert {:ok, %{state: :staged}} =
             [created, transition("building"), transition("staged")]
             |> chain()
             |> Projection.reduce()
  end

  test "a refused transition is recorded without moving the state, and only when it was genuinely refused" do
    created = {"DeploymentCreated", created()}

    refused =
      {"DeploymentTransitionRefused",
       %{"operation_id" => "dpo-1", "from" => "queued", "to" => "ready"}}

    assert {:ok, %{state: :queued}} = [created, refused] |> chain() |> Projection.reduce()

    legal =
      {"DeploymentTransitionRefused",
       %{"operation_id" => "dpo-1", "from" => "queued", "to" => "building"}}

    assert {:error, {:invalid_event, 2, :unfounded_refusal}} =
             [created, legal] |> chain() |> Projection.reduce()

    elsewhere =
      {"DeploymentTransitionRefused",
       %{"operation_id" => "dpo-1", "from" => "ready", "to" => "verifying"}}

    assert {:error, {:invalid_event, 2, :unfounded_refusal}} =
             [created, elsewhere] |> chain() |> Projection.reduce()
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
