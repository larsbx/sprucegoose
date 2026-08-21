defmodule SpruceGoose.Actors do
  @moduledoc """
  The actor registry: who may act, and over what.

  Deliberately *not* policy-protected itself. The registry is what every policy
  check reads, so subjecting it to those policies would make authorization
  depend on being authorized — the deadlock the vault's write gate avoids by
  leaving reads open. Access to the registry is gated in the CLI layer instead,
  where `admin` is required and the genesis bootstrap lives.
  """

  use Ash.Domain

  resources do
    resource(SpruceGoose.Actors.Actor)
    resource(SpruceGoose.Actors.Grant)
  end
end
