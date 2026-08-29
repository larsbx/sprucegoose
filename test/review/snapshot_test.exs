defmodule SpruceGoose.Review.SnapshotTest do
  @moduledoc """
  The review snapshot is consumed by a verifier that refuses anything it cannot
  check exactly, so these assertions restate that verifier's contract. If one
  of them fails, the protected dashboard stops reporting the backlog and says
  `BLOCKED` instead — which is a silent outage of the review, not a loud one.
  """
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Identity
  alias SpruceGoose.Review.Snapshot

  # Exactly the keys the adapter admits in the signed payload.
  @payload_keys ~w(authority count query schema snapshot source tasks total)
  @nonterminal ~w(blocked failed in_progress inbox proposed queued ready waiting)

  setup do
    # The signature needs a provisioned peer identity; the app mints one on
    # first use, which is fine in the test database.
    _ = Identity.Local.peer_id()

    root = Path.join(System.tmp_dir!(), "sg-review-test-#{System.unique_integer([:positive])}")
    vsn = to_string(Application.spec(:spruce_goose, :vsn))
    File.mkdir_p!(Path.join([root, "releases", vsn]))

    File.write!(
      Path.join([root, "releases", vsn, "governed-provenance.json"]),
      Jason.encode!(%{
        "source" => %{"commit" => String.duplicate("a", 40), "tree" => String.duplicate("b", 40)}
      })
    )

    System.put_env("RELEASE_ROOT", root)

    on_exit(fn ->
      System.delete_env("RELEASE_ROOT")
      File.rm_rf!(root)
    end)

    :ok
  end

  defp envelope(read \\ fn -> {[], 0} end), do: Snapshot.envelope(read)

  test "the envelope carries exactly the three keys the adapter admits" do
    env = envelope()

    assert Map.keys(env) |> Enum.sort() == ["ok", "receipt", "schema"]
    assert env["ok"] == true
    assert env["schema"] == "sprucegoose-review-envelope-v1"

    assert Map.keys(env["receipt"]) |> Enum.sort() ==
             ["algorithm", "payload", "payload_sha256", "signature"]
  end

  test "the receipt digest covers the bytes that are actually transmitted" do
    receipt = envelope()["receipt"]
    bytes = Base.decode64!(receipt["payload"])

    assert receipt["payload_sha256"] ==
             :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  end

  test "the signature verifies under the peer key, and rejects a tampered payload" do
    receipt = envelope()["receipt"]
    bytes = Base.decode64!(receipt["payload"])
    signature = Base.decode64!(receipt["signature"])

    public =
      bytes |> Jason.decode!() |> get_in(["authority", "peer_public_key"]) |> Base.decode64!()

    assert byte_size(signature) == 64
    assert :crypto.verify(:eddsa, :none, bytes, signature, [public, :ed25519])
    refute :crypto.verify(:eddsa, :none, bytes <> "x", signature, [public, :ed25519])
  end

  test "the signed payload states the contract the adapter compares by equality" do
    body = envelope()["receipt"]["payload"] |> Base.decode64!() |> Jason.decode!()

    assert Map.keys(body) |> Enum.sort() == @payload_keys
    assert body["schema"] == "sprucegoose-review-snapshot-v1"
    assert body["query"] == %{"page_size" => 500, "states" => Enum.sort(@nonterminal)}
    assert Map.keys(body["authority"]) |> Enum.sort() == ["actor", "kind", "peer_public_key"]
    assert Map.keys(body["source"]) |> Enum.sort() == ["commit", "module_md5", "tree"]
  end

  test "source identity is the running module, in the form the adapter matches" do
    body = envelope()["receipt"]["payload"] |> Base.decode64!() |> Jason.decode!()

    assert body["source"]["module_md5"] =~ ~r/\A[0-9a-f]{32}\z/

    assert body["source"]["module_md5"] ==
             Snapshot.module_info(:md5) |> Base.encode16(case: :lower)
  end

  test "the snapshot token has the shape the adapter's PG_SNAPSHOT expects" do
    body = envelope()["receipt"]["payload"] |> Base.decode64!() |> Jason.decode!()

    assert body["snapshot"] =~ ~r/\A\d+:\d+:(?:\d+(?:,\d+)*)?\z/
  end

  test "count reflects the rows returned and total the whole match" do
    read = fn -> {[%{"id" => "tsk-20260101T000000Z-abcdef12"}], 7} end
    body = envelope(read)["receipt"]["payload"] |> Base.decode64!() |> Jason.decode!()

    assert body["count"] == 1
    assert body["total"] == 7
  end

  test "an unprovisioned node refuses to sign rather than minting a key" do
    Repo.query!("DELETE FROM spruce_goose_identity", [])

    assert_raise RuntimeError, ~r/has not been provisioned/, fn -> envelope() end
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM spruce_goose_identity", [])
  end
end
