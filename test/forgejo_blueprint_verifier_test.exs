defmodule SpruceGoose.ForgejoBlueprintVerifierTest do
  use ExUnit.Case, async: false

  alias SpruceGoose.Blueprints.ForgejoVerifier

  @commit String.duplicate("a", 40)
  @blob String.duplicate("b", 40)

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

  test "derives tree and digest from the exact commit and path bytes" do
    parent = self()
    bytes = "schema_version: 1\nproject: legible\n"

    request = fn opts ->
      send(parent, {:request, opts})

      cond do
        String.contains?(opts[:url], "/git/commits/") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{"sha" => @commit}
           }}

        String.contains?(opts[:url], "/git/trees/") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "tree" => [
                 %{"mode" => "100644", "path" => "README.md", "sha" => @blob, "type" => "blob"}
               ]
             }
           }}

        true ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{"encoding" => "base64", "content" => Base.encode64(bytes)}
           }}
      end
    end

    Application.put_env(:spruce_goose, :blueprint_http_request, request)

    raw_entry = "100644 README.md" <> <<0>> <> Base.decode16!(@blob, case: :lower)

    expected_tree =
      :crypto.hash(:sha, "tree #{byte_size(raw_entry)}\0" <> raw_entry)
      |> Base.encode16(case: :lower)

    assert {:ok, %{tree: ^expected_tree, digest: digest}} =
             ForgejoVerifier.verify("root/legible", @commit, ".sprucegoose/project.yaml")

    assert digest == :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    assert_receive {:request, commit_request}
    assert_receive {:request, tree_request}
    assert_receive {:request, content_request}
    assert commit_request[:url] =~ "/repos/root/legible/git/commits/#{@commit}"
    assert content_request[:params] == [ref: @commit]
    assert tree_request[:url] =~ "/git/trees/#{@commit}"
    assert Enum.any?(commit_request[:headers], &match?({"authorization", "token test-token"}, &1))
  end

  test "refuses a mismatched commit response" do
    Application.put_env(:spruce_goose, :blueprint_http_request, fn _opts ->
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "sha" => String.duplicate("d", 40),
           "commit" => %{"tree" => %{"sha" => @blob}}
         }
       }}
    end)

    assert {:error, "Forgejo commit verification returned HTTP 200"} =
             ForgejoVerifier.verify("root/legible", @commit, ".sprucegoose/project.yaml")
  end

  defp restore(key, nil), do: Application.delete_env(:spruce_goose, key)
  defp restore(key, value), do: Application.put_env(:spruce_goose, key, value)
end
