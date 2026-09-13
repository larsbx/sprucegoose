defmodule SpruceGoose.Deployment.ArtifactTest do
  use ExUnit.Case, async: true
  alias SpruceGoose.Deployment.Artifact

  test "digest types cannot substitute for each other even with identical bytes" do
    bytes = "artifact bytes"
    digest = sha256(bytes)
    {:ok, archive} = Artifact.new(:archive, digest)
    {:ok, image} = Artifact.new(:oci_image, digest)
    assert :ok = Artifact.verify_bytes(archive, :archive, bytes)
    assert :ok = Artifact.verify_bytes(image, :oci_image, bytes)

    assert {:error, :invalid_artifact_verification} =
             Artifact.verify_bytes(image, :archive, bytes)

    assert {:error, :artifact_digest_mismatch} =
             Artifact.verify_bytes(archive, :archive, bytes <> "!")

    assert {:error, :invalid_artifact_identity} =
             Artifact.new(:archive, String.replace_prefix(digest, "sha256:", ""))

    assert {:error, :invalid_artifact_identity} = Artifact.new(:unknown, digest)
    assert {:error, :invalid_artifact_identity} = Artifact.new(:archive, String.upcase(digest))
  end

  test "native file collection v1 preserves deterministic encoding and digest" do
    files = [{"z/empty", ""}, {"a", "content"}]
    expected = :erlang.term_to_binary({1, [{"a", "content"}, {"z/empty", ""}]}, [:deterministic])
    assert {:ok, artifact, ^expected} = Artifact.from_files(files)
    assert artifact.digest == sha256(expected)
    assert artifact.kind == :file_collection_v1
    assert {:ok, ^artifact, ^expected} = Artifact.from_files(Enum.reverse(files))
    assert :ok = Artifact.verify_files(artifact, files)

    assert {:error, :artifact_digest_mismatch} =
             Artifact.verify_files(artifact, [{"a", "changed"}])

    assert {:error, :invalid_artifact_verification} =
             Artifact.verify_bytes(artifact, :archive, expected)

    assert {:error, :invalid_artifact_verification} =
             Artifact.verify_bytes(artifact, :file_collection_v1, expected)
  end

  test "ambiguous file paths and malformed collections are refused" do
    for files <- [
          [],
          nil,
          [{"a", "1"}, {"a", "2"}],
          [{"../a", "x"}],
          [{"/a", "x"}],
          [{"a/./b", "x"}],
          [{"a//b", "x"}],
          [{"a" <> <<0>>, "x"}],
          [{"a", nil}]
        ] do
      assert {:error, :invalid_file_collection} = Artifact.from_files(files)
    end
  end

  defp sha256(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
