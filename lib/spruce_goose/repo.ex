defmodule SpruceGoose.Repo do
  use AshPostgres.Repo, otp_app: :spruce_goose

  def installed_extensions, do: ["ash-functions"]

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end
