defmodule SpruceGoose.ConstitutionalPathTest do
  use ExUnit.Case, async: true

  alias SpruceGoose.Kernel.ContentID
  alias SpruceGoose.Kernel.Constitution
  alias SpruceGoose.Kernel.Constitution.{EffectIntent, OntologyVersion}

  test "issues one deterministic authorization path without executing an effect" do
    assert {:ok, path} = Constitution.authorize(roots(), request())

    assert %OntologyVersion{} = path.ontology_version
    assert path.proposition.ontology_version_id == path.ontology_version.id
    assert path.claim.proposition_id == path.proposition.id
    assert path.claim.evidence_id == path.evidence.id
    assert path.justification.claim_id == path.claim.id
    assert path.resolution.justification_id == path.justification.id
    assert path.resolution.norm_id == path.norm.id
    assert path.resolution.grant_id == path.grant.id
    assert path.authorization.resolution_id == path.resolution.id
    assert %EffectIntent{executed?: false} = path.effect_intent
    assert path.effect_intent.authorization_id == path.authorization.id
    assert :ok = Constitution.verify(path, roots(), now())

    assert {:ok, replayed} = Constitution.authorize(roots(), request())
    assert replayed == path
  end

  test "refuses substitution anywhere in the certified chain" do
    assert {:ok, path} = Constitution.authorize(roots(), request())
    substituted = put_in(path.proposition.ontology_version_id, content_id("other-ontology"))

    assert {:error, :substituted_artifact} =
             Constitution.verify(substituted, roots(), now())
  end

  test "refuses a missing constitutive root" do
    assert {:error, {:missing_root, :interpreter}} =
             roots()
             |> Map.delete(:interpreter)
             |> Constitution.authorize(request())
  end

  test "refuses a grant from a stale revocation epoch" do
    stale_request = Map.put(request(), :grant_epoch_id, content_id("earlier-grant-epoch"))

    assert {:error, :stale_grant} = Constitution.authorize(roots(), stale_request)
  end

  test "refuses an effect not licensed to the subject and action" do
    assert {:error, :unauthorized_effect} =
             Constitution.authorize(roots(), %{request() | grant_action: "test"})

    assert {:error, :unauthorized_effect} =
             Constitution.authorize(roots(), %{
               request()
               | action: "deploy",
                 grant_action: "deploy"
             })
  end

  test "refuses undefined predicates and unbound referents" do
    assert {:error, :undefined_predicate} =
             Constitution.authorize(roots(), %{request() | defined_predicates: []})

    assert {:error, :unbound_referent} =
             Constitution.authorize(roots(), %{request() | bound_referents: []})
  end

  test "refuses unsupported claims and contested evidence" do
    assert {:error, :unsupported_claim} =
             Constitution.authorize(roots(), %{request() | claim_supported?: false})

    assert {:error, :contested_evidence} =
             Constitution.authorize(roots(), %{request() | evidence_status: :contested})
  end

  test "refuses incompatibility, insufficient authority, expiry, and conflicts" do
    assert {:error, :incompatible_ontology_and_norm} =
             Constitution.authorize(roots(), %{request() | ontology_norm_compatible?: false})

    assert {:error, :insufficient_authority} =
             Constitution.authorize(roots(), %{request() | authority: :insufficient})

    assert {:error, :expired_grant} =
             Constitution.authorize(roots(), %{request() | expires_at: now()})

    assert {:error, :unresolved_conflict} =
             Constitution.authorize(roots(), %{request() | conflicts: ["deny-rule"]})
  end

  test "refuses omission of deterministic input identity" do
    assert {:error, :nondeterministic_input} =
             request()
             |> Map.delete(:input_id)
             |> then(&Constitution.authorize(roots(), &1))
  end

  defp roots do
    Map.new(Constitution.required_roots(), fn root -> {root, content_id(Atom.to_string(root))} end)
  end

  defp request do
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
      grant_epoch_id: roots().grant_epoch,
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
