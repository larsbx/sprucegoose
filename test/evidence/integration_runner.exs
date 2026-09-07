# Non-sandbox integration runner for Change A.
#
# Deliberately NOT routed through test/test_helper.exs, DataCase, or default
# `mix test` discovery: that helper puts SpruceGoose.Repo into Sandbox :manual
# mode, and the sandbox is exactly what this lane must avoid. The spike
# (transcript e0babbda…) proved the production transaction semantics can only
# be observed on a real pool.
#
# Invoked via: mix test.evidence_integration
# Requires env: SG_EVIDENCE_TEST_URL_ABSENT, SG_EVIDENCE_TEST_URL_SEEDED
#   each pointing at a FRESH disposable database owned by this attempt.

defmodule Runner do
  @required_marker "sg-evidence-disposable"

  def fetch_env!(name) do
    case System.get_env(name) do
      nil -> abort("missing required env #{name}")
      "" -> abort("empty env #{name}")
      v -> v
    end
  end

  def abort(msg) do
    IO.puts(:stderr, "RUNNER_ABORT: #{msg}")
    System.halt(3)
  end

  # Structural target proof: never trust configuration, ask the server.
  def prove_target!(expected_db) do
    q = fn sql -> SpruceGoose.Repo.query!(sql, []).rows |> hd() |> hd() end
    live_db = q.("SELECT current_database()")
    live_port = q.("SHOW port")

    unless live_db == expected_db do
      abort("live database #{inspect(live_db)} != expected #{inspect(expected_db)}")
    end

    unless String.contains?(live_db, @required_marker) do
      abort("database #{inspect(live_db)} lacks disposable marker #{inspect(@required_marker)}")
    end

    pool = SpruceGoose.Repo.config()[:pool]

    if pool == Ecto.Adapters.SQL.Sandbox do
      abort("Sandbox pool is prohibited in the integration lane")
    end

    IO.puts("TARGET_PROOF db=#{live_db} port=#{live_port} pool=#{inspect(pool)}")
  end

  def start_repo!(url) do
    opts = [url: url, pool: DBConnection.ConnectionPool, pool_size: 3, log: false]
    Application.put_env(:spruce_goose, SpruceGoose.Repo, opts)
    {:ok, pid} = SpruceGoose.Repo.start_link(opts)
    pid
  end

  def assert_no_forbidden_supervision! do
    started = Application.started_applications() |> Enum.map(&elem(&1, 0))

    for app <- [:spruce_goose, :oban, :phoenix, :ash] do
      if app in started, do: abort("forbidden supervision started: #{app}")
    end

    IO.puts("SUPERVISION_CLEAN spruce_goose/oban/phoenix/ash all absent")
  end
end

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)
Runner.assert_no_forbidden_supervision!()

ExUnit.start(autorun: false)
Code.require_file("identity_integration_case.exs", __DIR__)

results =
  for {scenario, env, tag} <- [
        {:absent, "SG_EVIDENCE_TEST_URL_ABSENT", :absent},
        {:seeded, "SG_EVIDENCE_TEST_URL_SEEDED", :seeded}
      ] do
    url = Runner.fetch_env!(env)
    expected_db = url |> URI.parse() |> Map.get(:path) |> String.trim_leading("/")

    pid = Runner.start_repo!(url)
    Runner.prove_target!(expected_db)
    Application.put_env(:spruce_goose, :evidence_test_scenario, scenario)

    if scenario == :seeded do
      %{rows: [[pk]]} =
        SpruceGoose.Repo.query!(
          "SELECT peer_public_key FROM spruce_goose_identity WHERE id IS TRUE", [])

      Application.put_env(:spruce_goose, :evidence_test_public_key, pk)
    end

    result = ExUnit.run([SpruceGoose.Evidence.IdentityIntegrationCase], include: [tag], exclude: [:test])
    Supervisor.stop(pid)
    result
  end

failures = Enum.sum(Enum.map(results, &(&1.failures + &1.errors)))
IO.puts("INTEGRATION_TOTAL_FAILURES=#{failures}")
System.halt(if failures > 0, do: 1, else: 0)
