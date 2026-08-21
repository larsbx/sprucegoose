defmodule SpruceGoose.Artifacts.Store do
  @moduledoc """
  Retrieves bytes and derives receipts in the local content-addressed store.
  """

  @chunk 65_536
  @hex64 ~r/\A[0-9a-f]{64}\z/

  def put_bytes(bytes) when is_binary(bytes) do
    max = Application.fetch_env!(:spruce_goose, :artifact_max_bytes)

    cond do
      bytes == "" ->
        {:error, "artifact bytes must not be empty"}

      byte_size(bytes) > max ->
        {:error, "artifact bytes exceed #{max} bytes"}

      true ->
        digest = sha256(bytes)

        with :ok <- persist(digest, bytes) do
          {:ok, receipt(digest, byte_size(bytes))}
        end
    end
  end

  def put_bytes(_), do: {:error, "artifact bytes are required"}

  def verify(digest) when is_binary(digest) do
    if Regex.match?(@hex64, digest) do
      path = artifact_path(digest)

      with {:ok, %{type: :regular, size: size}} <- File.lstat(path),
           true <- size > 0 and size <= Application.fetch_env!(:spruce_goose, :artifact_max_bytes),
           {:ok, bytes} <- File.read(path),
           true <- byte_size(bytes) == size and sha256(bytes) == digest do
        {:ok, receipt(digest, size)}
      else
        {:error, :enoent} -> {:error, "content-addressed artifact does not exist"}
        _ -> {:error, "content-addressed artifact is corrupt"}
      end
    else
      {:error, "content digest must be lowercase 64-hex"}
    end
  end

  def verify(_), do: {:error, "content digest is required"}

  def retrieve(name, source_path, source_identity, verifier) do
    with :ok <- bounded(name, 128, "artifact name"),
         :ok <- bounded(source_identity, 512, "source identity"),
         :ok <- bounded(verifier, 64, "verifier"),
         {:ok, stat} <- regular_source(source_path),
         {:ok, digest, size, bytes} <- read_and_hash(source_path, stat),
         :ok <- persist(digest, bytes) do
      {:ok,
       %{
         "name" => name,
         "sha256" => digest,
         "size_bytes" => size,
         "storage_locator" => "cas:sha256:" <> digest,
         "source_identity" => source_identity,
         "retrieval_verifier" => verifier,
         "retrieval_verified_at" =>
           DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
       }}
    end
  end

  defp bounded(value, max, label) when is_binary(value) do
    if String.trim(value) != "" and byte_size(value) <= max,
      do: :ok,
      else: {:error, "#{label} must be nonblank and at most #{max} bytes"}
  end

  defp bounded(_, _, label), do: {:error, "#{label} is required"}

  defp regular_source(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular} = stat} ->
        {:ok, stat}

      {:ok, _} ->
        {:error, "artifact source must be a regular file"}

      {:error, reason} ->
        {:error, "cannot inspect artifact source: #{:file.format_error(reason)}"}
    end
  end

  defp regular_source(_), do: {:error, "artifact source path is required"}

  defp read_and_hash(path, stat) do
    max = Application.fetch_env!(:spruce_goose, :artifact_max_bytes)

    cond do
      stat.size == 0 -> {:error, "artifact source must not be empty"}
      stat.size > max -> {:error, "artifact source exceeds #{max} bytes"}
      true -> read_exact(path, stat)
    end
  end

  defp read_exact(path, before_stat) do
    with {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      try do
        {context, size, chunks} = stream(io, :crypto.hash_init(:sha256), 0, [])

        with {:ok, after_stat} <- File.stat(path),
             true <- stable?(before_stat, after_stat, size) do
          digest = context |> :crypto.hash_final() |> Base.encode16(case: :lower)
          {:ok, digest, size, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
        else
          _ -> {:error, "artifact source changed during retrieval"}
        end
      after
        File.close(io)
      end
    end
  end

  defp stream(io, context, size, chunks) do
    case IO.binread(io, @chunk) do
      :eof ->
        {context, size, chunks}

      {:error, reason} ->
        raise "artifact read failed: #{:file.format_error(reason)}"

      bytes ->
        stream(io, :crypto.hash_update(context, bytes), size + byte_size(bytes), [bytes | chunks])
    end
  end

  defp stable?(before_stat, after_stat, size),
    do:
      before_stat.size == size and after_stat.size == size and
        before_stat.mtime == after_stat.mtime and before_stat.inode == after_stat.inode

  defp persist(digest, bytes) do
    destination = artifact_path(digest)

    :ok = File.mkdir_p(Path.dirname(destination))

    if File.exists?(destination) do
      verify_existing(destination, digest, byte_size(bytes))
    else
      create(destination, digest, bytes)
    end
  end

  defp create(destination, digest, bytes) do
    case File.open(destination, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        result = IO.binwrite(io, bytes)
        sync = :file.sync(io)
        File.close(io)

        with :ok <- result,
             :ok <- sync,
             :ok <- File.chmod(destination, 0o400),
             do: :ok

      {:error, :eexist} ->
        verify_existing(destination, digest, byte_size(bytes))

      {:error, reason} ->
        {:error, "cannot persist artifact: #{:file.format_error(reason)}"}
    end
  end

  defp verify_existing(path, digest, size) do
    with {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) == size,
         true <- :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) == digest do
      :ok
    else
      _ -> {:error, "content-addressed artifact collision or corruption"}
    end
  end

  defp artifact_path(digest) do
    Application.fetch_env!(:spruce_goose, :artifact_store_root)
    |> Path.join("sha256")
    |> Path.join(digest)
  end

  defp receipt(digest, size),
    do: %{digest: digest, locator: "cas:sha256:" <> digest, size: size}

  defp sha256(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
