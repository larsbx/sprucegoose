defmodule SpruceGoose.MigrationUpgradeRepo do
  use Ecto.Repo,
    otp_app: :spruce_goose,
    adapter: Ecto.Adapters.Postgres
end

defmodule SpruceGoose.MigrationUpgradeTest do
  use ExUnit.Case, async: false

  alias SpruceGoose.MigrationUpgradeRepo, as: UpgradeRepo

  @migrations Path.expand("../priv/repo/migrations", __DIR__)

  test "hierarchy migration backfills a workflow created under the prior schema" do
    database = "sprucegoose_upgrade_#{System.unique_integer([:positive])}"

    config =
      SpruceGoose.Repo.config()
      |> Keyword.drop([:name, :pool, :pool_size])
      |> Keyword.put(:database, database)
      |> Keyword.put(:pool_size, 2)

    assert :ok = Ecto.Adapters.Postgres.storage_up(config)

    on_exit(fn ->
      if pid = Process.whereis(UpgradeRepo), do: GenServer.stop(pid)
      Ecto.Adapters.Postgres.storage_down(config)
    end)

    {:ok, _pid} = UpgradeRepo.start_link(config)

    Ecto.Migrator.run(UpgradeRepo, @migrations, :up, to: 20_260_727_002_051)

    Ecto.Adapters.SQL.query!(
      UpgradeRepo,
      """
      INSERT INTO workflows (workflow_id, definition)
      VALUES ('preexisting', '{"schema_version":1,"tasks":[{"id":"a","kind":"oban"}]}')
      """
    )

    Ecto.Migrator.run(UpgradeRepo, @migrations, :up, all: true)

    assert %{rows: [["preexisting", "preexisting", "legacy-import"]]} =
             Ecto.Adapters.SQL.query!(
               UpgradeRepo,
               """
               SELECT workflows.workflow_id, workflows.name, roadmaps.key
               FROM workflows
               JOIN roadmaps ON roadmaps.id = workflows.roadmap_id
               WHERE workflows.workflow_id = 'preexisting'
               """
             )

    assert %{rows: [["sprucegoose_task_dependency_graph"]]} =
             Ecto.Adapters.SQL.query!(
               UpgradeRepo,
               "SELECT property_graph_name FROM information_schema.property_graphs WHERE property_graph_name = 'sprucegoose_task_dependency_graph'"
             )

    Ecto.Migrator.run(UpgradeRepo, @migrations, :down, to: 20_260_810_133_000)

    assert %{rows: []} =
             Ecto.Adapters.SQL.query!(
               UpgradeRepo,
               "SELECT property_graph_name FROM information_schema.property_graphs WHERE property_graph_name = 'sprucegoose_task_dependency_graph'"
             )

    Ecto.Migrator.run(UpgradeRepo, @migrations, :up, all: true)

    assert %{rows: [["sprucegoose_task_dependency_graph"]]} =
             Ecto.Adapters.SQL.query!(
               UpgradeRepo,
               "SELECT property_graph_name FROM information_schema.property_graphs WHERE property_graph_name = 'sprucegoose_task_dependency_graph'"
             )

    GenServer.stop(UpgradeRepo)
  end
end
