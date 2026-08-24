defmodule SpruceGoose.Workflows.AccessMethod do
  @moduledoc """
  How an external runner reaches a verification target.

  The data layer never executes any of these; the value tells the runner which
  transport to use, keeping transport choice out of check logic.
  """
  use Ash.Type.Enum,
    values: [
      :local,
      :ssh,
      :container,
      :http
    ]
end
