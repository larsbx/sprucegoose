defmodule SpruceGoose.Evidence.IdentityIntegrationCase do
  @moduledoc """
  Identity custody cases for the non-sandbox lane.

  Every scenario owns a fresh disposable database created by the runner, so
  absence is established by *never provisioning*, not by deleting a row. No
  case here issues a delete against the identity table.
  """
  use ExUnit.Case, async: false

  alias SpruceGoose.Identity.Local

  # The runner sets this to :absent or :seeded before loading the case.
  defp scenario, do: Application.fetch_env!(:spruce_goose, :evidence_test_scenario)
  defp seeded_public_key, do: Application.get_env(:spruce_goose, :evidence_test_public_key)

  defp identity_count do
    %{rows: [[n]]} = SpruceGoose.Repo.query!("SELECT count(*) FROM spruce_goose_identity", [])
    n
  end

  describe "absent identity (fresh database, never provisioned)" do
    @describetag :absent

    test "harness precondition: the table is genuinely empty" do
      if scenario() != :absent, do: flunk("wrong scenario loaded")

      assert identity_count() == 0,
             "CONTAMINATED: migrations or startup provisioned an identity; " <>
               "do not delete the row to force the fixture"
    end

    test "fetch returns :identity_unavailable and creates nothing" do
      before = identity_count()
      assert {:error, :identity_unavailable} = Local.fetch_existing_identity()
      assert identity_count() == before
      assert identity_count() == 0
    end

    test "signing with absent identity refuses and does not provision" do
      digest = :crypto.hash(:sha256, "x")

      assert {:error, :identity_unavailable} =
               Local.sign_authority_evidence_digest(digest, <<0::256>>)

      assert identity_count() == 0
    end
  end

  describe "seeded identity (test-owned singleton)" do
    @describetag :seeded

    test "fetch returns the public half and algorithm" do
      assert {:ok, %{public_key: pk, algorithm: "ed25519"}} = Local.fetch_existing_identity()
      assert byte_size(pk) == 32
      assert pk == seeded_public_key()
    end

    test "fetch does not add a row or mutate the key" do
      before_count = identity_count()
      {:ok, %{public_key: pk1}} = Local.fetch_existing_identity()
      {:ok, %{public_key: pk2}} = Local.fetch_existing_identity()
      assert pk1 == pk2
      assert identity_count() == before_count
      assert identity_count() == 1
    end

    test "valid digest signs and verifies under the exact framing" do
      {:ok, %{public_key: pk}} = Local.fetch_existing_identity()
      digest = :crypto.hash(:sha256, "canonical-bytes")

      assert {:ok, r} = Local.sign_authority_evidence_digest(digest, pk)
      assert r.algorithm == "ed25519"
      assert byte_size(r.signature) == 64
      assert r.public_key == pk

      msg = Local.authority_evidence_message(digest)
      assert :crypto.verify(:eddsa, :none, msg, r.signature, [pk, :ed25519])
    end

    test "a one-byte digest change fails verification" do
      {:ok, %{public_key: pk}} = Local.fetch_existing_identity()
      digest = :crypto.hash(:sha256, "canonical-bytes")
      {:ok, r} = Local.sign_authority_evidence_digest(digest, pk)

      <<first, rest::binary>> = digest
      tampered = <<Bitwise.bxor(first, 1), rest::binary>>
      refute :crypto.verify(:eddsa, :none, Local.authority_evidence_message(tampered),
                            r.signature, [pk, :ed25519])
    end

    test "a wrong domain separator fails verification" do
      {:ok, %{public_key: pk}} = Local.fetch_existing_identity()
      digest = :crypto.hash(:sha256, "canonical-bytes")
      {:ok, r} = Local.sign_authority_evidence_digest(digest, pk)

      wrong = "sprucegoose-some-other-domain-v1\0" <> digest
      refute :crypto.verify(:eddsa, :none, wrong, r.signature, [pk, :ed25519])
    end

    test "expected-public-key mismatch is refused as :identity_changed" do
      digest = :crypto.hash(:sha256, "x")

      assert {:error, :identity_changed} =
               Local.sign_authority_evidence_digest(digest, :crypto.strong_rand_bytes(32))
    end

    test "private material never appears in return values or inspection" do
      {:ok, %{public_key: pk}} = Local.fetch_existing_identity()

      %{rows: [[priv]]} =
        SpruceGoose.Repo.query!(
          "SELECT peer_private_key FROM spruce_goose_identity WHERE id IS TRUE", [])

      digest = :crypto.hash(:sha256, "x")
      {:ok, r} = Local.sign_authority_evidence_digest(digest, pk)

      rendered = inspect(r, limit: :infinity, printable_limit: :infinity)
      refute rendered =~ Base.encode16(priv, case: :lower)
      refute rendered =~ Base.encode16(priv, case: :upper)
      refute r.signature == priv
      refute Map.has_key?(r, :private_key)
      refute Map.has_key?(r, :peer_private_key)
    end
  end
end
