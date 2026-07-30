defmodule SpruceGoose.IdentityLocalTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Identity.Local
  alias SpruceGoose.Repo

  setup do
    Repo.query!("DELETE FROM spruce_goose_identity", [])
    :ok
  end

  test "provisions and retains a matching Ed25519 keypair" do
    public_key = Local.peer_id()

    %{rows: [[^public_key, private_key]]} =
      Repo.query!(
        "SELECT peer_public_key, peer_private_key FROM spruce_goose_identity WHERE id IS TRUE",
        []
      )

    assert byte_size(public_key) == 32
    assert byte_size(private_key) == 32

    message = "sprucegoose-key-custody-proof"
    signature = :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])
    assert :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519])
  end

  test "concurrent provisioning converges on one retained keypair" do
    keys =
      1..8
      |> Task.async_stream(fn _ -> Local.peer_id() end, max_concurrency: 8)
      |> Enum.map(fn {:ok, key} -> key end)

    assert [_] = Enum.uniq(keys)
    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM spruce_goose_identity", [])
  end

  test "origin sequence remains monotone across a database client restart" do
    opts = Repo.config() |> Keyword.take([:hostname, :port, :username, :password, :database])

    {:ok, first_client} = Postgrex.start_link(opts)

    %{rows: [[first]]} =
      Postgrex.query!(first_client, "SELECT nextval('spruce_goose_origin_seq')", [])

    GenServer.stop(first_client)

    {:ok, second_client} = Postgrex.start_link(opts)

    %{rows: [[second]]} =
      Postgrex.query!(second_client, "SELECT nextval('spruce_goose_origin_seq')", [])

    GenServer.stop(second_client)

    assert second > first
  end

  test "database rejects mutation of either key half" do
    Local.peer_id()
    {other_public, other_private} = :crypto.generate_key(:eddsa, :ed25519)

    assert_raise Postgrex.Error, ~r/peer keypair is immutable/, fn ->
      Repo.query!("UPDATE spruce_goose_identity SET peer_public_key = $1", [other_public])
    end

    assert_raise Postgrex.Error, ~r/peer keypair is immutable/, fn ->
      Repo.query!("UPDATE spruce_goose_identity SET peer_private_key = $1", [other_private])
    end
  end
end
