defmodule SpruceGoose.ArtifactStoreTest do
  use ExUnit.Case, async: false

  alias SpruceGoose.Artifacts.Store

  setup do
    root = Path.join(System.tmp_dir!(), "sprucegoose-artifact-store-#{System.unique_integer()}")
    previous = Application.fetch_env!(:spruce_goose, :artifact_store_root)
    Application.put_env(:spruce_goose, :artifact_store_root, root)

    on_exit(fn ->
      Application.put_env(:spruce_goose, :artifact_store_root, previous)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "stores bytes once and verifies their content identity" do
    assert {:ok, receipt} = Store.put_bytes("bounded evidence")
    assert receipt.digest == sha256("bounded evidence")
    assert receipt.locator == "cas:sha256:" <> receipt.digest
    assert receipt.size == 16
    assert {:ok, ^receipt} = Store.verify(receipt.digest)
    assert {:ok, ^receipt} = Store.put_bytes("bounded evidence")

    path =
      Path.join([
        Application.fetch_env!(:spruce_goose, :artifact_store_root),
        "sha256",
        receipt.digest
      ])

    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o440
    assert File.stat!(Path.dirname(path)).mode |> Bitwise.band(0o7777) == 0o2750
  end

  test "verification refuses corrupted bytes" do
    assert {:ok, receipt} = Store.put_bytes("original")

    path =
      Path.join([
        Application.fetch_env!(:spruce_goose, :artifact_store_root),
        "sha256",
        receipt.digest
      ])

    File.chmod!(path, 0o600)
    File.write!(path, "corrupt")

    assert {:error, "content-addressed artifact is corrupt"} = Store.verify(receipt.digest)
  end

  defp sha256(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
