defmodule SpruceGoose.Deployment.OperationTest do
  use ExUnit.Case, async: true
  alias SpruceGoose.Deployment.{Artifact, Operation}

  @now ~U[2026-09-10 12:00:00Z]
  @digest "sha256:" <> String.duplicate("a", 64)

  defp request(action \\ :deploy) do
    {:ok, artifact} = Artifact.new(:archive, @digest)
    {:ok, operation} = Operation.request("op-1", "dep-1", action, artifact, @now)
    operation
  end

  defp receipt(operation) do
    %{
      operation_id: operation.operation_id,
      deployment_id: operation.deployment_id,
      action: operation.action,
      artifact: operation.artifact,
      observed_at: @now,
      status: :succeeded,
      evidence_digest: @digest
    }
  end

  test "deploy and rollback request and start never claim observed completion" do
    for action <- [:deploy, :rollback] do
      requested = request(action)
      assert Operation.event_type(requested) == "#{action}_requested"

      assert {:error, :invalid_completion_receipt} =
               Operation.observe(requested, receipt(requested), @now)

      assert {:ok, started} = Operation.start(requested, @now)
      assert Operation.event_type(started) == "#{action}_started"
      assert started.receipt == nil
      assert {:ok, completed} = Operation.observe(started, receipt(started), @now)
      assert Operation.event_type(completed) == "#{action}_observed_completed"

      assert {:ok, ^completed} =
               Operation.observe(completed, receipt(started), DateTime.add(@now, 3600))

      assert {:error, :conflicting_receipt} =
               Operation.observe(completed, %{receipt(started) | evidence_digest: "bad"}, @now)
    end
  end

  test "timeout requires inspection and never permits a second start" do
    {:ok, started} = Operation.start(request(), @now)
    assert {:error, :inspection_required} = Operation.start(started, @now)
    assert {:ok, unknown} = Operation.timeout(started)
    assert Operation.event_type(unknown) == "deploy_unknown"
    assert {:ok, ^unknown} = Operation.timeout(unknown)
    assert {:error, :inspection_required} = Operation.start(unknown, @now)

    assert {:ok, %{state: :observed_completed}} =
             Operation.observe(unknown, receipt(unknown), @now)
  end

  test "completion must match operation, deployment, action, artifact and fresh observation" do
    {:ok, started} = Operation.start(request(), @now)

    for changes <- [
          %{operation_id: "op-other"},
          %{deployment_id: "dep-other"},
          %{action: :rollback},
          %{artifact: %{started.artifact | kind: :oci_image}},
          %{status: :failed},
          %{observed_at: DateTime.add(@now, 1, :microsecond)},
          %{observed_at: DateTime.add(@now, -1)},
          %{evidence_digest: ""}
        ] do
      assert {:error, :invalid_completion_receipt} =
               Operation.observe(started, Map.merge(receipt(started), changes), @now)
    end

    assert {:error, :invalid_completion_receipt} = Operation.observe(started, %{}, @now)

    assert {:error, :invalid_completion_receipt} =
             Operation.observe(started, receipt(started), DateTime.add(@now, 901))

    assert {:ok, _} = Operation.observe(started, receipt(started), DateTime.add(@now, 900))
  end

  test "malformed requests and backwards time fail closed" do
    op = request()

    for args <- [
          ["", "dep", :deploy, op.artifact, @now],
          ["op", nil, :deploy, op.artifact, @now],
          ["op", "dep", :shell, op.artifact, @now],
          ["op", "dep", :deploy, %{op.artifact | digest: "bad"}, @now]
        ] do
      assert {:error, :invalid_operation} = apply(Operation, :request, args)
    end

    assert {:error, :invalid_operation_time} = Operation.start(op, DateTime.add(@now, -1))
    assert {:error, :invalid_operation_state} = Operation.timeout(op)
  end

  test "legacy executed events remain requests without rewriting historical names" do
    for name <- ["deploy_executed", "rollback_executed", "reclaim_executed"] do
      assert Operation.legacy_evidence_class(name) == :request_only
    end

    assert Operation.legacy_evidence_class("state_changed") == :unclassified
  end
end
