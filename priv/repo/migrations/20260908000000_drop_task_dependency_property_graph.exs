defmodule SpruceGoose.Repo.Migrations.DropTaskDependencyPropertyGraph do
  use Ecto.Migration

  # `SpruceGoose.Workflows.Graph` reads dependency edges relationally, so the
  # property graph is unreferenced. Drop it where a beta server created it.
  #
  # The probe is required, not defensive: on a GA server `DROP PROPERTY GRAPH`
  # is a parse error, so it must not be sent at all. `information_schema
  # .property_graphs` exists only where SQL/PGQ does, which makes its presence
  # the capability test and the object test in one query.
  @graph "sprucegoose_task_dependency_graph"

  def up do
    repo().query!("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'information_schema'
          AND table_name = 'property_graphs'
      ) THEN
        IF EXISTS (
          SELECT 1 FROM information_schema.property_graphs
          WHERE property_graph_name = '#{@graph}'
        ) THEN
          EXECUTE 'DROP PROPERTY GRAPH #{@graph}';
        END IF;
      END IF;
    END
    $$;
    """)
  end

  # Deliberately irreversible. Recreating the graph would reintroduce the
  # unreleased-beta dependency this migration exists to remove, and nothing
  # reads the object.
  def down, do: :ok
end
