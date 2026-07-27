defmodule Orchestrator.MigrationUpgradeRepo do
  use Ecto.Repo,
    otp_app: :orchestrator,
    adapter: Ecto.Adapters.Postgres
end

defmodule Orchestrator.MigrationUpgradeTest do
  use ExUnit.Case, async: false

  alias Orchestrator.MigrationUpgradeRepo, as: UpgradeRepo

  @migrations Path.expand("../priv/repo/migrations", __DIR__)

  test "hierarchy migration backfills a workflow created under the prior schema" do
    database = "orchestrator_upgrade_#{System.unique_integer([:positive])}"

    config =
      Orchestrator.Repo.config()
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

    GenServer.stop(UpgradeRepo)
  end
end
