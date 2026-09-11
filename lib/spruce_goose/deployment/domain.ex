defmodule SpruceGoose.Deployment.Domain do
  @moduledoc """
  Typed authority for release acceptance, deployment lifecycle, execution
  authorization, and execution tracking.

  One authoritative deployment record lives here. Host observations describe
  what is running; they never become a competing policy authority.
  """

  use Ash.Domain

  authorization do
    authorize(:when_requested)
  end

  resources do
    resource(SpruceGoose.Deployment.Release)
    resource(SpruceGoose.Deployment.Record)
    resource(SpruceGoose.Deployment.Authorization)
    resource(SpruceGoose.Deployment.Operation)
  end
end
