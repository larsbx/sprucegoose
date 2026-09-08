defmodule SpruceGoose.Kernel.EventLedger do
  @moduledoc """
  Port for ordered, immutable certified events.

  `verify/2` re-derives an event's identity from its stored canonical bytes, so
  a ledger can prove it did not alter what it holds. That is not the same as
  *independent* verification, which this port used to claim: the canonical form
  is Erlang External Term Format, so recomputing an identity requires the BEAM.
  See `SpruceGoose.Kernel.Canonical` and
  `docs/decisions/2026-09-08-canonical-form.md`.
  """

  alias SpruceGoose.Kernel.{CertifiedEvent, ContentID}

  @callback append(term(), CertifiedEvent.t()) ::
              {:ok, ContentID.t(), term()} | {:error, atom()}
  @callback read(term(), String.t()) :: {:ok, [CertifiedEvent.t()]} | {:error, atom()}
  @callback verify(term(), ContentID.t()) :: :ok | {:error, atom()}
end
