defmodule SpruceGoose.Blueprints.ForgejoVerifier do
  @moduledoc "Verify blueprint identity and bytes through Forgejo's read API."

  @behaviour SpruceGoose.Blueprints.SourceVerifier
  @hex40 ~r/\A[0-9a-f]{40}\z/

  @impl true
  def verify(repository, commit, path) do
    with {:ok, {owner, repo}} <- repository_parts(repository),
         :ok <- valid_commit(commit),
         {:ok, token} <- token(),
         request = Application.get_env(:spruce_goose, :blueprint_http_request, &Req.request/1),
         {:ok, tree} <- fetch_tree(owner, repo, commit, token, request),
         {:ok, bytes} <- fetch_bytes(owner, repo, commit, path, token, request) do
      {:ok, %{tree: tree, digest: sha256(bytes), bytes: bytes}}
    end
  end

  defp fetch_tree(owner, repo, commit, token, request) do
    commit_url = api_url("/repos/#{segment(owner)}/#{segment(repo)}/git/commits/#{commit}")

    case request.(method: :get, url: commit_url, headers: auth(token), receive_timeout: 10_000) do
      {:ok,
       %{
         status: 200,
         body: %{"sha" => ^commit}
       }} ->
        fetch_tree_entries(owner, repo, commit, token, request)

      {:ok, %{status: status}} ->
        {:error, "Forgejo commit verification returned HTTP #{status}"}

      {:error, reason} ->
        {:error, "Forgejo commit verification failed: #{inspect(reason)}"}
    end
  end

  defp fetch_tree_entries(owner, repo, commit, token, request) do
    tree_url = api_url("/repos/#{segment(owner)}/#{segment(repo)}/git/trees/#{commit}")

    case request.(method: :get, url: tree_url, headers: auth(token), receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"tree" => entries}}} when is_list(entries) ->
        git_tree_id(entries)

      {:ok, %{status: status}} ->
        {:error, "Forgejo tree fetch returned HTTP #{status}"}

      {:error, reason} ->
        {:error, "Forgejo tree fetch failed: #{inspect(reason)}"}
    end
  end

  defp git_tree_id(entries) do
    with {:ok, encoded} <- encode_entries(entries) do
      object = "tree #{byte_size(encoded)}\0" <> encoded
      {:ok, :crypto.hash(:sha, object) |> Base.encode16(case: :lower)}
    end
  end

  defp encode_entries(entries) do
    entries
    |> Enum.sort_by(fn entry ->
      suffix = if entry["type"] == "tree", do: "/", else: ""
      entry["path"] <> suffix
    end)
    |> Enum.reduce_while({:ok, <<>>}, fn entry, {:ok, bytes} ->
      mode = entry["mode"] |> to_string() |> String.trim_leading("0")
      path = entry["path"]
      oid = entry["sha"]

      with true <- mode != "" and is_binary(path) and path != "",
           true <- is_binary(oid) and Regex.match?(@hex40, oid),
           {:ok, raw_oid} <- Base.decode16(oid, case: :lower) do
        {:cont, {:ok, bytes <> mode <> " " <> path <> <<0>> <> raw_oid}}
      else
        _ -> {:halt, {:error, "Forgejo returned an invalid tree entry"}}
      end
    end)
  end

  defp fetch_bytes(owner, repo, commit, path, token, request) do
    encoded_path = path |> String.split("/") |> Enum.map_join("/", &segment/1)
    url = api_url("/repos/#{segment(owner)}/#{segment(repo)}/contents/#{encoded_path}")

    case request.(
           method: :get,
           url: url,
           headers: auth(token),
           params: [ref: commit],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: %{"encoding" => "base64", "content" => content}}}
      when is_binary(content) ->
        case Base.decode64(String.replace(content, ~r/\s+/, "")) do
          {:ok, bytes} when byte_size(bytes) > 0 -> {:ok, bytes}
          _ -> {:error, "Forgejo returned invalid or empty blueprint bytes"}
        end

      {:ok, %{status: status}} ->
        {:error, "Forgejo blueprint fetch returned HTTP #{status}"}

      {:error, reason} ->
        {:error, "Forgejo blueprint fetch failed: #{inspect(reason)}"}
    end
  end

  defp token do
    path =
      Application.get_env(
        :spruce_goose,
        :forgejo_read_token_file,
        "/home/admin-papa/.config/icm-forgejo/admin-token"
      )

    with {:ok, stat} <- File.stat(path),
         true <- Bitwise.band(stat.mode, 0o077) == 0,
         {:ok, value} <- File.read(path),
         token when token != "" <- String.trim(value) do
      {:ok, token}
    else
      _ -> {:error, "owner-only Forgejo read token is unavailable"}
    end
  end

  defp repository_parts(repository) do
    case String.split(repository, "/") do
      [owner, repo] when owner != "" and repo != "" -> {:ok, {owner, repo}}
      _ -> {:error, "repository must be OWNER/REPO"}
    end
  end

  defp valid_commit(commit) do
    if Regex.match?(@hex40, commit), do: :ok, else: {:error, "commit must be lowercase 40-hex"}
  end

  defp api_url(path) do
    base =
      Application.get_env(
        :spruce_goose,
        :forgejo_api_url,
        "https://ubuntu-8gb-hil-1.tail2188e6.ts.net:8448/api/v1"
      )

    String.trim_trailing(base, "/") <> path
  end

  defp auth(token), do: [{"authorization", "token " <> token}, {"accept", "application/json"}]
  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
