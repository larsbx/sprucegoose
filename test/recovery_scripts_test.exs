defmodule SpruceGoose.RecoveryScriptsTest do
  use ExUnit.Case, async: true

  @root "ops/mama-authority/recovery"

  test "PostgreSQL 19 rehearsal is private-socket only and rejects host authentication" do
    prepare = File.read!(Path.join(@root, "prepare-pg19-upgrade-rehearsal.sh"))
    actor = File.read!(Path.join(@root, "run-actor-migration-on-pg19-rehearsal.sh"))

    assert prepare =~ "--auth-local=trust --auth-host=reject"
    refute prepare =~ "--auth=trust"
    assert actor =~ "-c listen_addresses="
    refute actor =~ "listen_addresses=127.0.0.1"
    assert actor =~ "socket_dir"
  end

  test "every rehearsal signal trap terminates and cleanup ownership precedes starts" do
    for name <- [
          "prepare-pg19-upgrade-rehearsal.sh",
          "run-pg19-upgrade-rehearsal.sh",
          "run-actor-migration-on-pg19-rehearsal.sh"
        ] do
      script = File.read!(Path.join(@root, name))

      assert script =~ "trap cleanup_processes EXIT" or script =~ "trap finalize_exit EXIT" or
               script =~ "trap cleanup_process EXIT" or script =~ "trap stop_clone EXIT"

      assert script =~ "trap 'exit 129' HUP"
      assert script =~ "trap 'exit 130' INT"
      assert script =~ "trap 'exit 143' TERM"
    end

    prepare = File.read!(Path.join(@root, "prepare-pg19-upgrade-rehearsal.sh"))
    actor = File.read!(Path.join(@root, "run-actor-migration-on-pg19-rehearsal.sh"))
    assert before?(prepare, "started=1", "pg_ctl\" -D \"$old_data\" -l")
    assert before?(actor, "pg_running=1", "pg_ctl\" -D \"$pg_data\" -l")
    assert before?(actor, "app_running=1", "systemd-run --user")
  end

  test "signal cleanup has executable clone and app interruption probes" do
    prepare = File.read!(Path.join(@root, "prepare-pg19-upgrade-rehearsal.sh"))
    actor = File.read!(Path.join(@root, "run-actor-migration-on-pg19-rehearsal.sh"))
    probe_path = Path.join(@root, "probe-rehearsal-signal-cleanup.sh")

    assert prepare =~ "CORR7_REHEARSAL_HOLD_AFTER_CLONE_START_SECONDS"
    assert actor =~ "CORR7_REHEARSAL_HOLD_AFTER_APP_START_SECONDS"
    assert File.exists?(probe_path)
    assert Bitwise.band(File.stat!(probe_path).mode, 0o111) == 0o111

    probe = File.read!(probe_path)
    assert probe =~ ~s(kill -s "$signal" "$pid")
    assert probe =~ ~s([[ "$status" == "$expected_status" ]])
    assert probe =~ "sprucegoose-corr7-pg19.service"
    assert probe =~ "sprucegoose-postgresql.service"
    assert probe =~ "sprucegoose.service"
  end

  test "upgrade inventory exercises and preserves database-global settings" do
    upgrade = File.read!(Path.join(@root, "run-pg19-upgrade-rehearsal.sh"))

    assert upgrade =~ "left join pg_roles role on role.oid=setting.setrole"
    assert upgrade =~ "setting.setrole=0 or role.rolname !~ '^pg_'"
    assert upgrade =~ "corr7.rehearsal_inventory_marker"
  end

  test "disposable candidate receives no live credentials or signing secrets" do
    actor = File.read!(Path.join(@root, "run-actor-migration-on-pg19-rehearsal.sh"))

    refute actor =~ ~s(. "$live_env")
    refute actor =~ ~s(printf 'export TOKEN_SIGNING_SECRET=%q\\n' "$TOKEN_SIGNING_SECRET")
    assert actor =~ "rehearsal_token_signing_secret"
    assert actor =~ "ecto://postgres@localhost"
    assert actor =~ "export DATABASE_SSL=false"
  end

  test "rehearsal evidence is fresh and bound to run, tree, scripts, artifacts, and clusters" do
    prepare = File.read!(Path.join(@root, "prepare-pg19-upgrade-rehearsal.sh"))
    upgrade = File.read!(Path.join(@root, "run-pg19-upgrade-rehearsal.sh"))
    actor = File.read!(Path.join(@root, "run-actor-migration-on-pg19-rehearsal.sh"))

    for script <- [prepare, upgrade, actor] do
      assert script =~ "CORR7_REHEARSAL_RUN_ID"
      assert script =~ "sha256sum"
    end

    assert prepare =~ "run-start"
    assert prepare =~ "system_identifier"
    assert upgrade =~ ~s("$log_dir/pg_upgrade-check.log" -nt "$root/run-start")
    assert upgrade =~ "rm -rf -- \"$evidence\""
    assert actor =~ "CORR7_EXPECTED_TREE"
    assert actor =~ "CORR7_EXPECTED_ARCHIVE_SHA256"
    assert actor =~ "CORR7_PROVENANCE"
    assert actor =~ "SHA256SUMS"
  end

  test "signal harness records append-only run-bound HUP INT and TERM receipts" do
    body = File.read!(Path.join(@root, "probe-rehearsal-signal-cleanup.sh"))

    assert body =~ "CORR7_REHEARSAL_RUN_ID"
    assert body =~ "signal_evidence"
    assert body =~ "HUP) expected_status=129"
    assert body =~ "INT) expected_status=130"
    assert body =~ "TERM) expected_status=143"
    assert body =~ ~s([[ ! -e "$receipt" ]])
    assert body =~ "signal.signal(signal.SIGINT, signal.SIG_DFL)"
    assert body =~ "CORR7_EXPECTED_TREE"
    assert body =~ "CORR7_EXPECTED_ARCHIVE_SHA256"
    assert body =~ "expected_tree=%s"
    assert body =~ "expected_archive_sha256=%s"
    assert body =~ "sha256sum"
    assert body =~ "chmod 0400"
  end

  test "registry lock probe proves the mutation backend waits on its holder" do
    actor = File.read!(Path.join(@root, "run-actor-migration-on-pg19-rehearsal.sh"))

    assert actor =~ "holder_backend_pid"
    assert actor =~ "mutation_backend_pid"
    assert actor =~ "wait_event_type = 'Lock'"
    assert actor =~ "wait_event = 'advisory'"
    assert actor =~ "pg_blocking_pids"
  end

  test "canonical data-directory guard rejects a symlink alias to live PGDATA" do
    guard = @root |> Path.join("assert-disposable-pgdata.sh") |> Path.expand()
    assert File.regular?(guard)

    root = Path.join(System.tmp_dir!(), "corr7-pgdata-#{System.unique_integer([:positive])}")
    live = Path.join(root, "live")
    candidate = Path.join(root, "candidate")
    alias_path = Path.join(root, "live-alias")
    File.mkdir_p!(live)
    File.mkdir_p!(candidate)
    File.ln_s!(live, alias_path)
    on_exit(fn -> File.rm_rf!(root) end)

    {_output, 0} = System.cmd(guard, [candidate, live, live], stderr_to_stdout: true)
    {output, status} = System.cmd(guard, [alias_path, live, live], stderr_to_stdout: true)
    assert status != 0
    assert output =~ "candidate PGDATA must not be a symlink"
  end

  test "canonical data-directory guard rejects every ancestor descendant and symlink-parent overlap" do
    guard = @root |> Path.join("assert-disposable-pgdata.sh") |> Path.expand()
    assert File.regular?(guard)

    root =
      Path.join(System.tmp_dir!(), "corr7-pgdata-overlap-#{System.unique_integer([:positive])}")

    live = Path.join(root, "live")
    nested_candidate = Path.join(live, "nested-candidate")
    candidate_parent = Path.join(root, "candidate-parent")
    nested_live = Path.join(candidate_parent, "nested-live")
    alias_parent = Path.join(root, "live-parent-alias")
    aliased_candidate = Path.join(alias_parent, "aliased-candidate")

    File.mkdir_p!(nested_candidate)
    File.mkdir_p!(nested_live)
    File.ln_s!(live, alias_parent)
    File.mkdir_p!(aliased_candidate)
    on_exit(fn -> File.rm_rf!(root) end)

    for {candidate, configured_live, actual_live, expected_message} <- [
          {nested_candidate, live, live, "candidate PGDATA overlaps live PGDATA"},
          {candidate_parent, nested_live, nested_live, "candidate PGDATA overlaps live PGDATA"},
          {aliased_candidate, live, live, "candidate PGDATA path contains symlink component"}
        ] do
      {output, status} =
        System.cmd(guard, [candidate, configured_live, actual_live], stderr_to_stdout: true)

      assert status != 0
      assert output =~ expected_message
    end
  end

  test "canonical guard rejects a mount point nested below the destructive root" do
    guard = @root |> Path.join("assert-disposable-pgdata.sh") |> Path.expand()

    root =
      Path.join(System.tmp_dir!(), "corr7-nested-mount-#{System.unique_integer([:positive])}")

    live = Path.join(root, "live")
    candidate = Path.join(root, "candidate")
    nested_mount = Path.join(candidate, "foreign-storage")
    mountinfo = Path.join(root, "mountinfo")
    test_guard = Path.join(root, "assert-disposable-pgdata-test.sh")

    File.mkdir_p!(live)
    File.mkdir_p!(nested_mount)

    File.write!(
      mountinfo,
      "1 0 0:1 / / rw - ext4 /dev/root rw\n" <>
        "2 1 0:2 / #{nested_mount} rw - ext4 /dev/foreign rw\n"
    )

    guard
    |> File.read!()
    |> String.replace("/proc/self/mountinfo", mountinfo)
    |> then(&File.write!(test_guard, &1))

    File.chmod!(test_guard, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    {output, status} = System.cmd(test_guard, [candidate, live, live], stderr_to_stdout: true)
    assert status != 0
    assert output =~ "candidate PGDATA contains mount point at or below destructive root"
    assert output =~ nested_mount
  end

  test "preparation applies canonical and mount guards before deleting its root" do
    guard = File.read!(Path.join(@root, "assert-disposable-pgdata.sh"))
    prepare = File.read!(Path.join(@root, "prepare-pg19-upgrade-rehearsal.sh"))

    assert guard =~ "/proc/self/mountinfo"
    assert guard =~ "candidate and live PGDATA resolve on different mounts"
    assert prepare =~ "pgdata_guard="
    assert before?(prepare, ~s("$pgdata_guard" "$root"), ~s(rm -rf -- "$root"))
  end

  test "clean actor evidence is finalized from EXIT after cleanup and live-service checks" do
    actor = File.read!(Path.join(@root, "run-actor-migration-on-pg19-rehearsal.sh"))

    assert actor =~ "completion-status.txt"
    assert actor =~ "exit_status=0"
    assert actor =~ "cleanup=PASS"
    assert actor =~ "live_postgresql=active"
    assert actor =~ "live_application=active"
    assert actor =~ "trap finalize_exit EXIT"
    assert before?(actor, "cleanup_processes", "completion-status.txt")
  end

  test "signal receipt checksum sidecars are relocatable" do
    probe = File.read!(Path.join(@root, "probe-rehearsal-signal-cleanup.sh"))

    assert probe =~ ~s|cd -- "$(dirname -- "$receipt")"|
    assert probe =~ ~s|sha256sum -- "$(basename -- "$receipt")"|
    refute probe =~ ~s|sha256sum "$receipt" > "$checksum"|
  end

  test "actor authorization and restart checks use a bounded existing task read" do
    actor = File.read!(Path.join(@root, "run-actor-migration-on-pg19-rehearsal.sh"))

    refute actor =~ "run_client task list --as recovery-agent"
    assert actor =~ "sample_task_id"
    assert actor =~ "select task_id from workflow_tasks"
    assert length(Regex.scan(~r/run_client task show .* --as recovery-agent/, actor)) == 2
  end

  test "reviewed client, actor grants, roles, and memberships are exact" do
    actor = File.read!(Path.join(@root, "run-actor-migration-on-pg19-rehearsal.sh"))
    upgrade = File.read!(Path.join(@root, "run-pg19-upgrade-rehearsal.sh"))

    assert actor =~ "d07cc14bff1d4384176f829d9c130a09e82425bc7326fe5370ffc9785ad6b9b9"
    assert actor =~ "expected_grants"
    refute actor =~ "from actor_grants grant"
    assert actor =~ "from actor_grants actor_grant"
    refute actor =~ ~s([[ "$grant_count" -ge 1 ]])

    for field <-
          ~w(rolinherit rolcreaterole rolcreatedb rolbypassrls rolconnlimit rolvaliduntil) do
      assert upgrade =~ field
    end

    assert upgrade =~ "pg_db_role_setting"
    assert upgrade =~ "setconfig"
    assert upgrade =~ "pg_auth_members"
    assert upgrade =~ "sha256(convert_to(coalesce(rolpassword, ''), 'UTF8'))"
    refute upgrade =~ "(rolpassword is null)"

    assert actor =~ "expected_migration_versions"
    assert actor =~ "before_migration_versions"
    assert actor =~ "after_migration_versions"
    assert actor =~ "registry_write_lock_probe=PASS"
    assert actor =~ "sprucegoose:actor-registry-write"
    assert actor =~ ~s(rm -rf -- "$evidence")
    assert actor =~ "pg_stat_activity"
    assert actor =~ "wait_event = 'PgSleep'"
    refute actor =~ "grep -Fxq 'registry-lock-held'"
  end

  test "recovery ICM documents exact hardened rehearsal and production blocker" do
    document = File.read!(Path.join(@root, "README.md"))

    assert document =~ "e96b374d6ccb0d068b058a64ed03764594b104d46662aa07c2351d8a8ed107e6"
    assert document =~ "d07cc14bff1d4384176f829d9c130a09e82425bc7326fe5370ffc9785ad6b9b9"
    assert document =~ "probe-rehearsal-signal-cleanup.sh clone \"$signal\""
    assert document =~ "probe-rehearsal-signal-cleanup.sh app \"$signal\""
    assert document =~ "`129` for HUP, `130` for INT, and `143` for TERM"
    assert document =~ "$HOME/recovery-rehearsal/corr7-signal-evidence"
    assert document =~ "tasks=581->581"
    assert document =~ "registry_write_lock_probe=PASS"
    assert document =~ "`admin-papa` as the sole production Genesis human"
    assert document =~ "host authentication is rejected"
    assert document =~ "production cutover is still blocked"
    assert document =~ "PostgreSQL 19 as **Beta 2**"
    assert document =~ "PostgreSQL 18.4 is the current supported GA major"
    assert document =~ "beta2 rehearsal must not be promoted"
    assert document =~ "Mama (`100.69.235.63`) → Evergreen"
    assert document =~ "/home/admin-papa/sprucegoose-production-backups/corr-7"
    assert document =~ "no bind mount or same-path assumption is permitted"
    assert document =~ "not a backup or restore receipt"
  end

  defp before?(body, first, second) do
    {first_at, _} = :binary.match(body, first)
    {second_at, _} = :binary.match(body, second)
    first_at < second_at
  end
end
