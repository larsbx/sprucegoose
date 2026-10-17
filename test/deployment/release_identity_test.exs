defmodule SpruceGoose.Deployment.ReleaseIdentityTest do
  use ExUnit.Case, async: true

  alias SpruceGoose.Deployment.ReleaseIdentity

  @attrs %{
    forge_instance: "forgejo-mama",
    repository: "root/sprucegoose",
    source_commit: String.duplicate("a", 40),
    pipeline_number: 42,
    pipeline_digest: String.duplicate("c", 64),
    artifacts: %{archive: "sha256:" <> String.duplicate("1", 64)}
  }

  test "a well-formed identity is accepted and its ID is deterministic" do
    assert {:ok, release} = ReleaseIdentity.new(@attrs)
    assert {:ok, "rel-" <> digest} = ReleaseIdentity.id(release)
    assert byte_size(digest) == 64

    string_keyed =
      @attrs
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
      |> Map.put("artifacts", %{"archive" => @attrs.artifacts.archive})

    assert {:ok, ^release} = ReleaseIdentity.new(string_keyed)
    assert ReleaseIdentity.artifact_hex(release, :archive) == String.duplicate("1", 64)
    assert ReleaseIdentity.artifact_hex(release, :image) == nil
  end

  test "each identity field is validated and any change alters the ID" do
    {:ok, base} = ReleaseIdentity.new(@attrs)
    {:ok, base_id} = ReleaseIdentity.id(base)

    refusals = [
      {:forge_instance, ""},
      {:repository, "sprucegoose"},
      {:source_commit, "main"},
      {:pipeline_number, 0},
      {:pipeline_number, "42"},
      {:pipeline_digest, "sha256:" <> String.duplicate("c", 64)}
    ]

    for {field, value} <- refusals do
      assert {:error, {:invalid_field, ^field}} =
               ReleaseIdentity.new(Map.put(@attrs, field, value))
    end

    {:ok, other} = ReleaseIdentity.new(%{@attrs | pipeline_number: 43})
    {:ok, other_id} = ReleaseIdentity.id(other)
    refute other_id == base_id
  end

  test "artifact digests must be typed, prefixed, and drawn from the closed kind set" do
    assert {:error, :artifacts_required} = ReleaseIdentity.new(Map.put(@attrs, :artifacts, %{}))
    assert {:error, :artifacts_required} = ReleaseIdentity.new(Map.delete(@attrs, :artifacts))

    assert {:error, {:invalid_artifact, :tarball}} =
             ReleaseIdentity.new(
               Map.put(@attrs, :artifacts, %{tarball: @attrs.artifacts.archive})
             )

    assert {:error, {:invalid_artifact, :archive}} =
             ReleaseIdentity.new(
               Map.put(@attrs, :artifacts, %{archive: String.duplicate("1", 64)})
             )

    # Archive, file collection, and image digests remain distinct facts.
    typed = %{
      archive: "sha256:" <> String.duplicate("1", 64),
      files: "sha256:" <> String.duplicate("2", 64),
      image: "sha256:" <> String.duplicate("3", 64)
    }

    assert {:ok, release} = ReleaseIdentity.new(Map.put(@attrs, :artifacts, typed))

    assert ReleaseIdentity.to_map(release)["artifacts"] == %{
             "archive" => typed.archive,
             "files" => typed.files,
             "image" => typed.image
           }
  end
end
