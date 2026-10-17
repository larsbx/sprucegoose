defmodule SpruceGoose.Blueprints.ForgejoVerifier do
  @moduledoc """
  Verify blueprint identity and bytes through Forgejo's read API.

  ## What "verify" has to mean here

  `blueprint apply` and `task instantiate` are the only paths by which new work
  enters SpruceGoose — `task add` and `inbox promote` are retired. So whatever
  this module accepts becomes admitted work, and the tree and digest it records
  become that work's provenance.

  This previously made three API calls and cross-checked exactly one field
  (`commit.sha`). It discarded the tree identity the commit object itself
  declared, recomputed a tree id from a separately-fetched listing with nothing
  to compare it against, and hashed the `contents/` response without checking it
  against the blob the tree names. Every recorded value was internally
  consistent and independently arbitrary: a Forgejo instance that was
  compromised, misconfigured, or impersonated returned a "verified" blueprint.

  Now every fetched object is checked against an identity some *other* response
  committed to first:

  ```text
  commit.sha            == the commit that was asked for
  sha1(tree entries)    == commit.commit.tree.sha        (declared by the commit)
  sha1(subtree entries) == the entry sha that was followed (declared by its parent)
  sha1(blob bytes)      == the blob entry sha            (declared by the tree)
  ```

  Each link is a git object identity recomputed from the bytes actually
  returned, so the chain is only satisfiable by the real objects. Substituting
  any one of them requires a SHA-1 preimage, not merely a cooperative server.
  """

  @behaviour SpruceGoose.Blueprints.SourceVerifier
  @hex40 ~r/\A[0-9a-f]{40}\z/

  @impl true
  def verify(repository, commit, path) do
    with {:ok, {owner, repo}} <- repository_parts(repository),
         :ok <- valid_commit(commit),
         {:ok, segments} <- path_segments(path),
         {:ok, token} <- token(),
         request = Application.get_env(:spruce_goose, :blueprint_http_request, &Req.request/1),
         {:ok, declared_tree} <- fetch_commit(owner, repo, commit, token, request),
         {:ok, entries} <- fetch_tree(owner, repo, commit, declared_tree, token, request),
         {:ok, blob} <- resolve_blob(owner, repo, entries, segments, token, request),
         {:ok, bytes} <- fetch_bytes(owner, repo, commit, path, blob, token, request) do
      {:ok, %{tree: declared_tree, digest: sha256(bytes), bytes: bytes}}
    end
  end

  # The commit is the only object whose identity the caller supplies, so it is
  # the root of trust for everything below it. Its declared tree is what makes
  # the tree listing checkable at all.
  defp fetch_commit(owner, repo, commit, token, request) do
    url = api_url("/repos/#{segment(owner)}/#{segment(repo)}/git/commits/#{commit}")

    case request.(method: :get, url: url, headers: auth(token), receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"sha" => ^commit, "commit" => %{"tree" => %{"sha" => tree}}}}}
      when is_binary(tree) ->
        if Regex.match?(@hex40, tree),
          do: {:ok, tree},
          else: {:error, "Forgejo returned an invalid tree identity for #{commit}"}

      {:ok, %{status: 200, body: %{"sha" => ^commit}}} ->
        {:error, "Forgejo commit #{commit} declared no tree identity"}

      {:ok, %{status: status}} ->
        {:error, "Forgejo commit verification returned HTTP #{status}"}

      {:error, reason} ->
        {:error, "Forgejo commit verification failed: #{inspect(reason)}"}
    end
  end

  defp fetch_tree(owner, repo, commit, expected, token, request) do
    with {:ok, entries} <- tree_entries(owner, repo, commit, token, request),
         {:ok, recomputed} <- git_tree_id(entries) do
      if recomputed == expected do
        {:ok, entries}
      else
        {:error,
         "Forgejo tree listing for #{commit} hashes to #{recomputed}, but the commit " <>
           "declares tree #{expected}"}
      end
    end
  end

  defp tree_entries(owner, repo, reference, token, request) do
    url = api_url("/repos/#{segment(owner)}/#{segment(repo)}/git/trees/#{reference}")

    case request.(method: :get, url: url, headers: auth(token), receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"tree" => entries}}} when is_list(entries) ->
        {:ok, entries}

      {:ok, %{status: status}} ->
        {:error, "Forgejo tree fetch returned HTTP #{status}"}

      {:error, reason} ->
        {:error, "Forgejo tree fetch failed: #{inspect(reason)}"}
    end
  end

  # Walk the path one segment at a time. Each subtree is fetched by the sha its
  # parent named and re-hashed against that sha, so a substituted directory is
  # refused at the level it was substituted rather than silently traversed.
  defp resolve_blob(_owner, _repo, entries, [name], _token, _request) do
    case Enum.find(entries, &(&1["path"] == name and &1["type"] == "blob")) do
      %{"sha" => sha} when is_binary(sha) ->
        if Regex.match?(@hex40, sha),
          do: {:ok, sha},
          else: {:error, "Forgejo returned an invalid blob identity for #{name}"}

      _ ->
        {:error, "#{name} is not a file in the verified tree"}
    end
  end

  defp resolve_blob(owner, repo, entries, [name | rest], token, request) do
    case Enum.find(entries, &(&1["path"] == name and &1["type"] == "tree")) do
      %{"sha" => sha} when is_binary(sha) ->
        with true <- Regex.match?(@hex40, sha),
             {:ok, subtree} <- tree_entries(owner, repo, sha, token, request),
             {:ok, ^sha} <- git_tree_id(subtree) do
          resolve_blob(owner, repo, subtree, rest, token, request)
        else
          {:ok, other} when is_binary(other) ->
            {:error, "Forgejo subtree #{name} hashes to #{other}, but its parent names #{sha}"}

          false ->
            {:error, "Forgejo returned an invalid tree identity for #{name}"}

          error ->
            error
        end

      _ ->
        {:error, "#{name} is not a directory in the verified tree"}
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
           # A recursive listing would put "/" in `path`, which changes both the
           # sort order and the encoded bytes, so the recomputed id would be
           # wrong in a way no other check would catch. Refuse instead.
           false <- String.contains?(path, "/"),
           true <- is_binary(oid) and Regex.match?(@hex40, oid),
           {:ok, raw_oid} <- Base.decode16(oid, case: :lower) do
        {:cont, {:ok, bytes <> mode <> " " <> path <> <<0>> <> raw_oid}}
      else
        _ -> {:halt, {:error, "Forgejo returned an invalid tree entry"}}
      end
    end)
  end

  defp fetch_bytes(owner, repo, commit, path, blob, token, request) do
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
        with {:ok, bytes} <- decode_content(content),
             :ok <- bounded(bytes),
             :ok <- matches_blob(bytes, blob) do
          {:ok, bytes}
        end

      {:ok, %{status: status}} ->
        {:error, "Forgejo blueprint fetch returned HTTP #{status}"}

      {:error, reason} ->
        {:error, "Forgejo blueprint fetch failed: #{inspect(reason)}"}
    end
  end

  defp decode_content(content) do
    case Base.decode64(String.replace(content, ~r/\s+/, "")) do
      {:ok, bytes} when byte_size(bytes) > 0 -> {:ok, bytes}
      _ -> {:error, "Forgejo returned invalid or empty blueprint bytes"}
    end
  end

  # `receive_timeout` bounds how long the response may take, not how large it
  # may be. A manifest is a small YAML file; anything else is refused rather
  # than buffered.
  defp bounded(bytes) do
    max = Application.fetch_env!(:spruce_goose, :blueprint_max_bytes)

    if byte_size(bytes) <= max,
      do: :ok,
      else: {:error, "blueprint bytes exceed #{max} bytes"}
  end

  # The tree named this blob before the bytes were requested, so this is what
  # binds the manifest to the commit rather than to the server's goodwill.
  defp matches_blob(bytes, blob) do
    object = "blob #{byte_size(bytes)}\0" <> bytes
    actual = :crypto.hash(:sha, object) |> Base.encode16(case: :lower)

    if actual == blob,
      do: :ok,
      else: {:error, "Forgejo blueprint bytes hash to blob #{actual}, but the tree names #{blob}"}
  end

  defp repository_parts(repository) do
    case String.split(repository, "/") do
      [owner, repo] when owner != "" and repo != "" -> {:ok, {owner, repo}}
      _ -> {:error, "repository must be OWNER/REPO"}
    end
  end

  defp path_segments(path) when is_binary(path) do
    segments = String.split(path, "/", trim: false)

    if segments != [] and Enum.all?(segments, &(&1 != "" and &1 != "." and &1 != "..")),
      do: {:ok, segments},
      else: {:error, "blueprint path must be a relative path with no empty segments"}
  end

  defp path_segments(_path), do: {:error, "blueprint path is required"}

  defp valid_commit(commit) do
    if is_binary(commit) and Regex.match?(@hex40, commit),
      do: :ok,
      else: {:error, "commit must be lowercase 40-hex"}
  end

  defp token do
    path = Application.fetch_env!(:spruce_goose, :forgejo_read_token_file)

    with {:ok, stat} <- File.stat(path),
         true <- Bitwise.band(stat.mode, 0o077) == 0,
         {:ok, value} <- File.read(path),
         token when token != "" <- String.trim(value) do
      {:ok, token}
    else
      _ -> {:error, "owner-only Forgejo read token is unavailable"}
    end
  end

  defp api_url(path) do
    base = Application.fetch_env!(:spruce_goose, :forgejo_api_url)
    String.trim_trailing(base, "/") <> path
  end

  defp auth(token), do: [{"authorization", "token " <> token}, {"accept", "application/json"}]
  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
