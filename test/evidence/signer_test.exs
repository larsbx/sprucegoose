defmodule SpruceGoose.Evidence.SignerTest do
  @moduledoc """
  The signer orchestrates custody calls; it must never touch key material
  itself. Database-backed cases are tagged :integration.
  """
  use ExUnit.Case, async: true

  alias SpruceGoose.Evidence.Signer

  describe "custody boundary" do
    test "signer never references the private half or peer_id/0" do
      src = File.read!("lib/spruce_goose/evidence/signer.ex")
      refute src =~ "peer_private_key"
      refute src =~ "peer_id"
      refute src =~ ":crypto.sign", "signing must be delegated to Identity.Local"
    end
  end

  describe "digest contract" do
    test "refuses a payload digest that is not 32 bytes" do
      assert {:error, :invalid_digest} = Signer.sign_payload_digest(<<0::size(248)>>, <<0::256>>)
    end
  end

  describe "refusal mapping" do
    test "absent identity maps to AUTHORITY_SIGNING_KEY_UNAVAILABLE" do
      assert Signer.refusal_token({:error, :identity_unavailable}) ==
               "AUTHORITY_SIGNING_KEY_UNAVAILABLE"
    end

    test "changed identity maps to AUTHORITY_SIGNING_IDENTITY_CHANGED" do
      assert Signer.refusal_token({:error, :identity_changed}) ==
               "AUTHORITY_SIGNING_IDENTITY_CHANGED"
    end

    test "invalid identity and unsupported algorithm are distinct typed refusals" do
      assert Signer.refusal_token({:error, :identity_invalid}) =~ "IDENTITY"
      assert Signer.refusal_token({:error, :unsupported_algorithm}) =~ "ALGORITHM"
    end
  end

  describe "local verification before emission" do
    @describetag :integration

    test "a signature that fails local verification blocks emission" do
      digest = :crypto.hash(:sha256, "payload")
      {:ok, %{public_key: pk}} = SpruceGoose.Identity.Local.fetch_existing_identity()
      assert {:ok, env} = Signer.sign_payload_digest(digest, pk)
      assert Signer.verify_envelope(env, digest) == :ok

      tampered = %{env | signature: :crypto.strong_rand_bytes(64)}
      assert {:error, :signature_verification_failed} = Signer.verify_envelope(tampered, digest)
    end
  end
end
