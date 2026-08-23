defmodule SpruceGoose.Kernel.Admission do
  @moduledoc """
  Admission-time verification for the constitutional path.

  Closes two defects that a shape-only checker cannot catch:

    * roots that are well-formed but fabricated, resolving to no stored bytes;
    * declared companion digests that are never checked against actual bytes.

  Both are refusals here rather than downstream, because a fabricated root is
  indistinguishable from a real one once it has been accepted. This module
  resolves through the `SpruceGoose.Kernel.ArtifactStore` port and never
  assumes a specific adapter.

  Admission establishes that roots resolve and declared bytes match. It does
  not adopt a specification, grant authority, or execute an effect.
  """

  alias SpruceGoose.Kernel.{Constitution, ContentID}

  @hex64 ~r/^[0-9a-f]{64}$/

  @spec required_roots() :: [atom()]
  def required_roots, do: Constitution.required_roots()

  @doc """
  Resolves every required root against the artifact store.

  Refuses unrecognized roots before validating known ones, so an attacker
  cannot smuggle an extra root past a per-root loop.
  """
  @spec resolve_roots(term(), map()) ::
          {:ok, map()} | {:error, {atom(), atom()}}
  def resolve_roots(store, roots) when is_map(roots) do
    with :ok <- reject_unrecognized(roots) do
      Enum.reduce_while(required_roots(), {:ok, %{}}, fn root, {:ok, acc} ->
        case resolve_root(store, roots, root) do
          {:ok, bytes} -> {:cont, {:ok, Map.put(acc, root, bytes)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  @doc """
  Verifies a declared 64-hex digest against bytes actually held by the store.

  A digest that resolves to nothing is a substitution, not a missing optional.
  """
  @spec verify_declared_bytes(term(), String.t()) :: :ok | {:error, atom()}
  def verify_declared_bytes(store, declared) when is_binary(declared) do
    if Regex.match?(@hex64, declared) do
      content_id = %ContentID{algorithm: :sha256, digest: declared}

      case fetch(store, content_id) do
        {:ok, bytes} -> ContentID.verify(content_id, bytes)
        {:error, _reason} -> {:error, :substituted_artifact}
      end
    else
      {:error, :invalid_declared_digest}
    end
  end

  def verify_declared_bytes(_store, _declared), do: {:error, :invalid_declared_digest}

  @doc """
  Resolves roots and declared bytes, then runs the constitutional path.

  Refuses before authorization when any root is unresolvable.
  """
  @spec admit(term(), map(), map(), String.t()) ::
          {:ok, struct()} | {:error, term()}
  def admit(store, roots, request, declared_digest) do
    with {:ok, _resolved} <- resolve_roots(store, roots),
         :ok <- verify_declared_bytes(store, declared_digest) do
      Constitution.authorize(roots, request)
    end
  end

  defp reject_unrecognized(roots) do
    required = MapSet.new(required_roots())

    roots
    |> Map.keys()
    |> Enum.find_value(:ok, fn key ->
      if MapSet.member?(required, key), do: false, else: {:error, {:unrecognized_root, key}}
    end)
  end

  defp resolve_root(store, roots, root) do
    case Map.fetch(roots, root) do
      {:ok, %ContentID{algorithm: :sha256} = content_id} ->
        case fetch(store, content_id) do
          {:ok, bytes} -> {:ok, bytes}
          {:error, _reason} -> {:error, {:unresolvable_root, root}}
        end

      {:ok, _invalid} ->
        {:error, {:invalid_root, root}}

      :error ->
        {:error, {:missing_root, root}}
    end
  end

  defp fetch(%module{} = store, %ContentID{} = content_id),
    do: module.get(store, content_id)

  defp fetch(_store, _content_id), do: {:error, :invalid_store}
end
