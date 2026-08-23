defmodule SpruceGoose.KernelAdmissionTest do
  @moduledoc """
  Adversarial proofs for the two high defects found in the maqasid revision-3
  oracle: roots were shape-checked but never resolved, and declared companion
  bytes were never verified against actual bytes.

  These cases mirror the executed attacks T2, T3, and T4.
  """
  use ExUnit.Case, async: true

  alias SpruceGoose.Kernel.{Admission, ContentID}
  alias SpruceGoose.Kernel.Memory.ArtifactStore

  describe "root resolution (defect: shape-only root checking)" do
    test "resolves every root that is present in the artifact store" do
      {store, roots} = seeded_store_and_roots()

      assert {:ok, resolved} = Admission.resolve_roots(store, roots)
      assert Map.keys(resolved) |> Enum.sort() == Enum.sort(Admission.required_roots())
    end

    test "refuses a fabricated root that is well-formed but resolves to nothing (T2)" do
      {store, roots} = seeded_store_and_roots()
      fabricated = %ContentID{algorithm: :sha256, digest: String.duplicate("b", 64)}

      for root <- Admission.required_roots() do
        poisoned = Map.put(roots, root, fabricated)

        assert {:error, {:unresolvable_root, ^root}} =
                 Admission.resolve_roots(store, poisoned),
               "fabricated #{root} root must refuse, not pass a shape check"
      end
    end

    test "refuses a missing root" do
      {store, roots} = seeded_store_and_roots()

      assert {:error, {:missing_root, :norm}} =
               Admission.resolve_roots(store, Map.delete(roots, :norm))
    end

    test "refuses a structurally invalid root" do
      {store, roots} = seeded_store_and_roots()

      assert {:error, {:invalid_root, :policy}} =
               Admission.resolve_roots(store, Map.put(roots, :policy, "not-a-content-id"))
    end

    test "refuses unrecognized extra roots rather than ignoring them" do
      {store, roots} = seeded_store_and_roots()
      extra = Map.put(roots, :attacker_supplied, hd(Map.values(roots)))

      assert {:error, {:unrecognized_root, :attacker_supplied}} =
               Admission.resolve_roots(store, extra)
    end
  end

  describe "declared byte verification (defect: unverified spec_md_sha256)" do
    test "accepts a declaration whose digest matches the actual bytes" do
      store = ArtifactStore.new("test-adapter")
      bytes = "# SPEC agent-harness-governance\n"
      {:ok, receipt, store} = ArtifactStore.put(store, bytes)

      assert :ok = Admission.verify_declared_bytes(store, receipt.content_id.digest)
    end

    test "refuses a declared digest that matches no stored bytes (T3)" do
      store = ArtifactStore.new("test-adapter")
      {:ok, _receipt, store} = ArtifactStore.put(store, "# real spec bytes\n")

      assert {:error, :substituted_artifact} =
               Admission.verify_declared_bytes(store, String.duplicate("c", 64))
    end

    test "refuses a malformed declared digest" do
      store = ArtifactStore.new("test-adapter")

      assert {:error, :invalid_declared_digest} =
               Admission.verify_declared_bytes(store, "deadbeef")
    end
  end

  describe "admission composes resolution with the constitutional path" do
    test "refuses before authorization when a root is unresolvable (T4 posture)" do
      {store, roots} = seeded_store_and_roots()
      fabricated = %ContentID{algorithm: :sha256, digest: String.duplicate("d", 64)}
      poisoned = Map.put(roots, :ontology, fabricated)

      assert {:error, {:unresolvable_root, :ontology}} =
               Admission.admit(store, poisoned, request(roots), declared_digest(store))
    end

    test "a fully resolved root set reaches the constitutional path" do
      {store, roots} = seeded_store_and_roots()

      assert {:ok, path} = Admission.admit(store, roots, request(roots), declared_digest(store))
      assert path.effect_intent.executed? == false
    end
  end

  defp seeded_store_and_roots do
    store = ArtifactStore.new("test-adapter")

    Enum.reduce(Admission.required_roots(), {store, %{}}, fn root, {acc_store, acc_roots} ->
      {:ok, receipt, acc_store} =
        ArtifactStore.put(acc_store, "root-bytes:" <> Atom.to_string(root))

      {acc_store, Map.put(acc_roots, root, receipt.content_id)}
    end)
  end

  defp declared_digest(store) do
    store.artifacts |> Map.keys() |> hd() |> Map.fetch!(:digest)
  end

  defp request(roots) do
    %{
      subject: "sprucegoose-derivation-v1",
      action: "verify_artifact",
      predicate: "artifact_matches_declared_content",
      referent: "cas:sha256:" <> String.duplicate("a", 64),
      defined_predicates: ["artifact_matches_declared_content"],
      bound_referents: ["cas:sha256:" <> String.duplicate("a", 64)],
      observation_id: content_id("captured-observation"),
      input_id: content_id("deterministic-input"),
      claim_supported?: true,
      evidence_status: :accepted,
      ontology_norm_compatible?: true,
      authority: :sufficient,
      conflicts: [],
      grant_subject: "sprucegoose-derivation-v1",
      grant_action: "verify_artifact",
      grant_epoch_id: roots.grant_epoch,
      expires_at: DateTime.add(now(), 300, :second),
      now: now()
    }
  end

  defp now, do: ~U[2026-08-22 08:00:00.000000Z]

  defp content_id(value) do
    {:ok, id} = ContentID.derive(:sha256, value)
    id
  end
end
