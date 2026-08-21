defmodule SpruceGoose.Kernel.EventLedger do
  @moduledoc "Port for ordered, immutable, independently verifiable certified events."

  alias SpruceGoose.Kernel.{CertifiedEvent, ContentID}

  @callback append(term(), CertifiedEvent.t()) ::
              {:ok, ContentID.t(), term()} | {:error, atom()}
  @callback read(term(), String.t()) :: {:ok, [CertifiedEvent.t()]} | {:error, atom()}
  @callback verify(term(), ContentID.t()) :: :ok | {:error, atom()}
end
