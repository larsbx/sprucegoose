defmodule SpruceGoose.Repo.Migrations.AddTaskDependencyPropertyGraph do
  use Ecto.Migration

  # Retired 2026-09-08. This migration created the SQL/PGQ property graph
  # `sprucegoose_task_dependency_graph`. `CREATE PROPERTY GRAPH` exists only in
  # an unreleased PostgreSQL beta, so as written this migration made the schema
  # uncreatable on every supported GA release — no developer, CI runner, or
  # recovery environment could build the database at all.
  #
  # `SpruceGoose.Workflows.Graph` now selects dependency edges relationally and
  # reads no property graph. The object is dropped where it already exists by
  # `20260908000000_drop_task_dependency_property_graph`; it is no longer
  # created here, so a fresh database never depends on the beta.
  #
  # The body is emptied rather than the file deleted: this version is recorded
  # in `schema_migrations` on the live database, and removing it would make the
  # applied set and the reviewed set disagree.
  def up, do: :ok
  def down, do: :ok
end
