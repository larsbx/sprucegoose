defmodule SpruceGoose.Kernel.EventLedger do
  @moduledoc """
  Port for ordered, immutable certified events.

  `verify/2` re-derives an event's identity from its stored canonical bytes, so
  a ledger can prove it did not alter what it holds. Events written in the
  `jcs-v1` canonical form are also independently verifiable: any JSON
  implementation can recompute their identity from the exported ledger. Events
  in the legacy `etf-v1` form are verifiable only on the BEAM and are mapped
  to their `jcs-v1` identity by the re-rooting record. See
  `SpruceGoose.Kernel.Canonical` and `docs/certified-ledger.md`.
  """

  alias SpruceGoose.Kernel.{CertifiedEvent, ContentID}

  @callback append(term(), CertifiedEvent.t()) ::
              {:ok, ContentID.t(), term()} | {:error, atom()}
  @callback read(term(), String.t()) :: {:ok, [CertifiedEvent.t()]} | {:error, atom()}
  @callback verify(term(), ContentID.t()) :: :ok | {:error, atom()}
  @callback streams(term()) :: {:ok, [String.t()]} | {:error, atom()}
end
