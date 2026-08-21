defmodule SpruceGoose.Kernel.CertifiedEvent do
  @moduledoc "Immutable certified event whose identity excludes delivery metadata."

  alias SpruceGoose.Kernel.{Canonical, ContentID}

  @enforce_keys [
    :stream,
    :event_type,
    :idempotency_key,
    :payload,
    :roots,
    :canonical_bytes,
    :identity
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          stream: String.t(),
          event_type: String.t(),
          idempotency_key: String.t(),
          payload: map(),
          roots: map(),
          canonical_bytes: binary(),
          identity: ContentID.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) do
    with {:ok, stream} <- required_string(attrs, :stream),
         {:ok, event_type} <- required_string(attrs, :event_type),
         {:ok, idempotency_key} <- required_string(attrs, :idempotency_key),
         {:ok, payload} <- required_map(attrs, :payload),
         {:ok, roots} <- required_map(attrs, :roots),
         :ok <- require_roots(roots),
         {:ok, bytes} <-
           Canonical.encode(%{
             "event_type" => event_type,
             "idempotency_key" => idempotency_key,
             "payload" => payload,
             "roots" => roots,
             "stream" => stream
           }),
         {:ok, identity} <- ContentID.derive(:sha256, bytes) do
      {:ok,
       %__MODULE__{
         stream: stream,
         event_type: event_type,
         idempotency_key: idempotency_key,
         payload: payload,
         roots: roots,
         canonical_bytes: bytes,
         identity: identity
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_event}

  defp required_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_event}
    end
  end

  defp required_map(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_map(value) and not is_struct(value) -> {:ok, value}
      _ -> {:error, :invalid_event}
    end
  end

  defp require_roots(roots) when map_size(roots) > 0, do: :ok
  defp require_roots(_roots), do: {:error, :missing_roots}
end
