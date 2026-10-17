defmodule SpruceGoose.Deployment.Ledger do
  @moduledoc """
  Linked certified events on one deployment's stream.

  Each appended payload names the content identity of the event before it, so
  the stream is a hash chain inside the certified ledger: per-stream ordering
  and immutability come from the ledger, and the link makes a gap or a fork
  detectable on replay even if ordering metadata were lost.
  """

  alias SpruceGoose.Deployment.Projection
  alias SpruceGoose.Kernel.{CertifiedEvent, ShadowEvents}
  alias SpruceGoose.Kernel.Postgres.EventLedger

  def stream(deployment_id), do: "deployment:" <> deployment_id

  @doc "Every certified event on the deployment's stream, in order."
  def read(deployment_id), do: EventLedger.read(EventLedger.new(), stream(deployment_id))

  @doc "Replay the stream into a projection, refusing a broken or unlawful history."
  def project(deployment_id) do
    with {:ok, events} <- read(deployment_id) do
      Projection.reduce(events)
    end
  end

  @doc """
  Append one event linked to `previous` (the current head identity, or `nil`
  for creation). Call only inside the deployment's locked transaction.
  Returns the new head identity.
  """
  def append(deployment_id, event_type, payload, previous) when is_map(payload) do
    linked =
      Map.merge(payload, %{
        "schema" => Projection.schema(),
        "deployment_id" => deployment_id,
        "previous" => previous
      })

    with {:ok, roots} <- ShadowEvents.roots(),
         {:ok, event} <-
           CertifiedEvent.new(%{
             stream: stream(deployment_id),
             event_type: event_type,
             idempotency_key: "#{event_type}:#{previous || "genesis"}",
             payload: linked,
             roots: roots
           }),
         {:ok, identity, _ledger} <- EventLedger.append(EventLedger.new(), event) do
      {:ok, identity.digest}
    end
  end
end
