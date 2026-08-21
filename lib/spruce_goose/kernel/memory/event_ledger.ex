defmodule SpruceGoose.Kernel.Memory.EventLedger do
  @moduledoc "Reference in-memory EventLedger adapter for kernel proofs."

  @behaviour SpruceGoose.Kernel.EventLedger

  alias SpruceGoose.Kernel.{CertifiedEvent, ContentID}

  @enforce_keys [:adapter_id, :events, :idempotency]
  defstruct [:adapter_id, :events, :idempotency]

  def new(adapter_id) when is_binary(adapter_id) and adapter_id != "",
    do: %__MODULE__{adapter_id: adapter_id, events: [], idempotency: %{}}

  @impl true
  def append(%__MODULE__{} = ledger, %CertifiedEvent{} = event) do
    key = {event.stream, event.idempotency_key}

    case Map.fetch(ledger.idempotency, key) do
      {:ok, %ContentID{} = existing} when existing == event.identity ->
        {:ok, existing, ledger}

      {:ok, %ContentID{}} ->
        {:error, :idempotency_conflict}

      :error ->
        updated = %{
          ledger
          | events: ledger.events ++ [event],
            idempotency: Map.put(ledger.idempotency, key, event.identity)
        }

        {:ok, event.identity, updated}
    end
  end

  @impl true
  def read(%__MODULE__{} = ledger, stream) when is_binary(stream) do
    {:ok, Enum.filter(ledger.events, &(&1.stream == stream))}
  end

  @impl true
  def verify(%__MODULE__{} = ledger, %ContentID{} = identity) do
    case Enum.find(ledger.events, &(&1.identity == identity)) do
      nil -> {:error, :not_found}
      event -> ContentID.verify(identity, event.canonical_bytes)
    end
  end
end
