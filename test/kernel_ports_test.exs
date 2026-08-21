defmodule SpruceGoose.KernelPortsTest do
  use ExUnit.Case, async: true

  alias SpruceGoose.Kernel.{CertifiedEvent, ContentID}
  alias SpruceGoose.Kernel.Memory.{ArtifactStore, EventLedger}

  test "content identity binds canonical bytes and algorithm identity" do
    bytes = ~s({"project":"canary"})

    assert {:ok, id} = ContentID.derive(:sha256, bytes)
    assert id.algorithm == :sha256
    assert :ok = ContentID.verify(id, bytes)
    assert {:error, :content_mismatch} = ContentID.verify(id, bytes <> "!")
    assert {:error, :unsupported_algorithm} = ContentID.derive(:sha512, bytes)
  end

  test "artifact verification rejects altered bytes and receipts from another adapter" do
    store = ArtifactStore.new("canary-store")
    {:ok, receipt, store} = ArtifactStore.put(store, "baseline")

    assert {:ok, "baseline"} = ArtifactStore.get(store, receipt.content_id)
    assert :ok = ArtifactStore.verify(store, receipt)

    corrupted = put_in(store.artifacts[receipt.content_id], "altered")
    assert {:error, :content_mismatch} = ArtifactStore.verify(corrupted, receipt)

    wrong_algorithm = %{receipt.content_id | algorithm: :sha512}
    assert {:error, :unsupported_algorithm} = ContentID.verify(wrong_algorithm, "baseline")

    wrong_adapter = %{receipt | adapter_id: "other-store"}
    assert {:error, :wrong_adapter} = ArtifactStore.verify(store, wrong_adapter)
  end

  test "event identity excludes mutable delivery metadata" do
    attrs = %{
      stream: "project:canary",
      event_type: "GrandfatheredStateAccepted",
      idempotency_key: "canary-baseline-v1",
      payload: %{"baseline" => "sha256:abc"},
      roots: %{"schema" => "sha256:def"}
    }

    assert {:ok, first} = CertifiedEvent.new(Map.put(attrs, :delivery, %{attempts: 0}))
    assert {:ok, retried} = CertifiedEvent.new(Map.put(attrs, :delivery, %{attempts: 9}))
    assert first.identity == retried.identity
    assert first.canonical_bytes == retried.canonical_bytes
  end

  test "append is idempotent only for identical event content" do
    ledger = EventLedger.new("canary-ledger")
    {:ok, event} = certified_event("accepted")

    assert {:ok, identity, ledger} = EventLedger.append(ledger, event)
    assert {:ok, ^identity, same_ledger} = EventLedger.append(ledger, event)
    assert same_ledger == ledger
    assert {:ok, [^event]} = EventLedger.read(ledger, "project:canary")
    assert :ok = EventLedger.verify(ledger, identity)

    {:ok, conflicting} = certified_event("substituted")

    assert {:error, :idempotency_conflict} =
             EventLedger.append(ledger, conflicting)
  end

  defp certified_event(value) do
    CertifiedEvent.new(%{
      stream: "project:canary",
      event_type: "CanaryObserved",
      idempotency_key: "obs-1",
      payload: %{"value" => value},
      roots: %{"schema" => "sha256:def", "authority" => "sha256:123"}
    })
  end
end
