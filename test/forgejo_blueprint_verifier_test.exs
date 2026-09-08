defmodule SpruceGoose.ForgejoBlueprintVerifierTest do
  @moduledoc """
  Blueprint verification is the only path by which new work enters SpruceGoose,
  so these tests are about what the verifier *refuses*.

  Every fetched object must match an identity a previous response committed to:
  the commit names its tree, the tree names its subtrees and its blobs. The
  refusal cases below each break exactly one of those links and nothing else, so
  a regression that drops a check fails the test for that specific link.
  """

  use ExUnit.Case, async: false

  alias SpruceGoose.Blueprints.ForgejoVerifier

  @commit String.duplicate("a", 40)
  @bytes "schema_version: 1\nproject: legible\n"
  @path ".sprucegoose/project.yaml"

  setup do
    token_path =
      Path.join(System.tmp_dir!(), "forgejo-read-token-#{System.unique_integer([:positive])}")

    File.write!(token_path, "test-token\n")
    File.chmod!(token_path, 0o600)

    previous = %{
      token: Application.get_env(:spruce_goose, :forgejo_read_token_file),
      request: Application.get_env(:spruce_goose, :blueprint_http_request),
      url: Application.get_env(:spruce_goose, :forgejo_api_url)
    }

    Application.put_env(:spruce_goose, :forgejo_read_token_file, token_path)
    Application.put_env(:spruce_goose, :forgejo_api_url, "https://forgejo.test/api/v1")

    on_exit(fn ->
      File.rm(token_path)
      restore(:forgejo_read_token_file, previous.token)
      restore(:blueprint_http_request, previous.request)
      restore(:forgejo_api_url, previous.url)
    end)
  end

  test "derives tree and digest from the exact commit, tree, and blob identities" do
    parent = self()
    repository = build_repository()

    Application.put_env(:spruce_goose, :blueprint_http_request, fn opts ->
      send(parent, {:request, opts})
      respond(repository, opts)
    end)

    assert {:ok, %{tree: tree, digest: digest, bytes: bytes}} =
             ForgejoVerifier.verify("root/legible", @commit, @path)

    assert tree == repository.root_sha
    assert bytes == @bytes
    assert digest == :crypto.hash(:sha256, @bytes) |> Base.encode16(case: :lower)

    assert_receive {:request, commit_request}
    assert commit_request[:url] =~ "/repos/root/legible/git/commits/#{@commit}"
    assert Enum.any?(commit_request[:headers], &match?({"authorization", "token test-token"}, &1))
  end

  test "refuses a mismatched commit response" do
    Application.put_env(:spruce_goose, :blueprint_http_request, fn _opts ->
      {:ok, %Req.Response{status: 200, body: %{"sha" => String.duplicate("d", 40)}}}
    end)

    assert {:error, "Forgejo commit verification returned HTTP 200"} =
             ForgejoVerifier.verify("root/legible", @commit, @path)
  end

  test "refuses a commit that declares no tree identity" do
    Application.put_env(:spruce_goose, :blueprint_http_request, fn _opts ->
      {:ok, %Req.Response{status: 200, body: %{"sha" => @commit}}}
    end)

    assert {:error, message} = ForgejoVerifier.verify("root/legible", @commit, @path)
    assert message =~ "declared no tree identity"
  end

  test "refuses a root tree listing that does not hash to the commit's declared tree" do
    repository = build_repository()

    # One extra entry: the listing is well-formed and internally consistent, and
    # hashes to something the commit did not name.
    tampered =
      put_in(repository.trees[repository.root_sha], [
        %{
          "mode" => "040000",
          "path" => ".sprucegoose",
          "sha" => repository.dir_sha,
          "type" => "tree"
        },
        %{
          "mode" => "100644",
          "path" => "PLANTED.md",
          "sha" => blob_sha("planted"),
          "type" => "blob"
        }
      ])

    Application.put_env(:spruce_goose, :blueprint_http_request, &respond(tampered, &1))

    assert {:error, message} = ForgejoVerifier.verify("root/legible", @commit, @path)
    assert message =~ "but the commit declares tree #{repository.root_sha}"
  end

  test "refuses a subtree that does not hash to the identity its parent names" do
    repository = build_repository()

    tampered =
      put_in(repository.trees[repository.dir_sha], [
        %{
          "mode" => "100644",
          "path" => "project.yaml",
          "sha" => blob_sha("planted"),
          "type" => "blob"
        }
      ])

    Application.put_env(:spruce_goose, :blueprint_http_request, &respond(tampered, &1))

    assert {:error, message} = ForgejoVerifier.verify("root/legible", @commit, @path)
    assert message =~ "hashes to"
    assert message =~ "but its parent names #{repository.dir_sha}"
  end

  test "refuses blueprint bytes that do not hash to the blob the tree names" do
    repository = build_repository()
    tampered = %{repository | contents: "schema_version: 1\nproject: substituted\n"}

    Application.put_env(:spruce_goose, :blueprint_http_request, &respond(tampered, &1))

    assert {:error, message} = ForgejoVerifier.verify("root/legible", @commit, @path)
    assert message =~ "but the tree names #{repository.blob_sha}"
  end

  test "refuses a path that is absent from the verified tree" do
    repository = build_repository()
    Application.put_env(:spruce_goose, :blueprint_http_request, &respond(repository, &1))

    assert {:error, message} =
             ForgejoVerifier.verify("root/legible", @commit, ".sprucegoose/absent.yaml")

    assert message =~ "absent.yaml is not a file in the verified tree"
  end

  test "refuses a recursive tree listing rather than hashing it wrongly" do
    repository = build_repository()

    # Recursive entries carry "/" in `path`, which changes both the sort order
    # and the encoded bytes. Silently hashing them would produce a tree id that
    # is wrong in a way no other check catches.
    tampered =
      put_in(repository.trees[repository.root_sha], [
        %{
          "mode" => "100644",
          "path" => ".sprucegoose/project.yaml",
          "sha" => repository.blob_sha,
          "type" => "blob"
        }
      ])

    Application.put_env(:spruce_goose, :blueprint_http_request, &respond(tampered, &1))

    assert {:error, message} = ForgejoVerifier.verify("root/legible", @commit, @path)
    assert message =~ "invalid tree entry"
  end

  test "refuses blueprint bytes larger than the configured bound" do
    previous = Application.get_env(:spruce_goose, :blueprint_max_bytes)
    Application.put_env(:spruce_goose, :blueprint_max_bytes, 8)
    on_exit(fn -> Application.put_env(:spruce_goose, :blueprint_max_bytes, previous) end)

    repository = build_repository()
    Application.put_env(:spruce_goose, :blueprint_http_request, &respond(repository, &1))

    assert {:error, message} = ForgejoVerifier.verify("root/legible", @commit, @path)
    assert message =~ "exceed 8 bytes"
  end

  # -- a small in-memory git repository ---------------------------------------
  #
  # Real object identities rather than placeholder shas: every refusal above
  # depends on the verifier recomputing them, so a fixture with invented shas
  # would pass a verifier that checked nothing.

  defp build_repository do
    blob_sha = blob_sha(@bytes)

    dir_entries = [
      %{"mode" => "100644", "path" => "project.yaml", "sha" => blob_sha, "type" => "blob"}
    ]

    dir_sha = tree_sha(dir_entries)

    root_entries = [
      %{"mode" => "040000", "path" => ".sprucegoose", "sha" => dir_sha, "type" => "tree"}
    ]

    root_sha = tree_sha(root_entries)

    %{
      root_sha: root_sha,
      dir_sha: dir_sha,
      blob_sha: blob_sha,
      contents: @bytes,
      trees: %{root_sha => root_entries, dir_sha => dir_entries}
    }
  end

  defp respond(repository, opts) do
    url = opts[:url]

    cond do
      String.contains?(url, "/git/commits/") ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"sha" => @commit, "commit" => %{"tree" => %{"sha" => repository.root_sha}}}
         }}

      String.contains?(url, "/git/trees/") ->
        reference = url |> String.split("/git/trees/") |> List.last()

        case Map.fetch(repository.trees, resolve(repository, reference)) do
          {:ok, entries} -> {:ok, %Req.Response{status: 200, body: %{"tree" => entries}}}
          :error -> {:ok, %Req.Response{status: 404}}
        end

      true ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"encoding" => "base64", "content" => Base.encode64(repository.contents)}
         }}
    end
  end

  # The root tree is fetched by commit sha; every subtree by its own sha.
  defp resolve(repository, @commit), do: repository.root_sha
  defp resolve(_repository, reference), do: reference

  defp blob_sha(bytes),
    do: :crypto.hash(:sha, "blob #{byte_size(bytes)}\0" <> bytes) |> Base.encode16(case: :lower)

  defp tree_sha(entries) do
    encoded =
      entries
      |> Enum.sort_by(fn entry ->
        entry["path"] <> if(entry["type"] == "tree", do: "/", else: "")
      end)
      |> Enum.map_join(fn entry ->
        String.trim_leading(entry["mode"], "0") <>
          " " <> entry["path"] <> <<0>> <> Base.decode16!(entry["sha"], case: :lower)
      end)

    :crypto.hash(:sha, "tree #{byte_size(encoded)}\0" <> encoded) |> Base.encode16(case: :lower)
  end

  defp restore(key, nil), do: Application.delete_env(:spruce_goose, key)
  defp restore(key, value), do: Application.put_env(:spruce_goose, key, value)
end
