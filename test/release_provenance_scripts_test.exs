ExUnit.start()

defmodule SpruceGoose.ReleaseProvenanceScriptsTest do
  use ExUnit.Case, async: true

  @build Path.expand("../scripts/build-governed-release", __DIR__)
  @inspect Path.expand("../scripts/inspect-governed-release", __DIR__)
  @validate Path.expand("../scripts/validate-governed-release", __DIR__)

  test "dirty build rejects before output creation or mix invocation" do
    c = repo_fixture(true)
    {text, rc} = run(@build, [], c.root, c.env)
    assert rc == 2
    assert text =~ "dirty source rejected before output or build tool invocation"
    refute File.exists?(c.output)
    refute File.exists?(c.marker)
  end

  test "explicit dirty override is classified non-transferable before attempted tooling" do
    c = repo_fixture(true)
    evidence = Path.join(c.root, "dirty-evidence.txt")
    output = Path.join(tmp("dirty-output-parent"), "candidate")
    File.write!(evidence, "governed local evidence only\n")

    env =
      c.env ++
        [{"SPRUCE_GOOSE_ALLOW_DIRTY_EVIDENCE", "1"}, {"SPRUCE_GOOSE_DIRTY_EVIDENCE", evidence}] ++
        required_env(output)

    {text, rc} = run(@build, [], c.root, env)
    assert rc == 99, text
    assert text =~ "classification=non-transferable-dirty-evidence"
    assert File.exists?(c.marker)
    refute File.exists?(output)
  end

  test "required build inputs fail with controlled errors before output or tool invocation" do
    c = repo_fixture(false)
    {text, rc} = run(@build, [], c.root, c.env)
    assert rc == 2
    assert text =~ "explicit SPRUCE_GOOSE_BUILDER is required"
    refute File.exists?(c.output)
    refute File.exists?(c.marker)
  end

  test "inside-worktree nonexistent output is refused before creation or mix invocation" do
    c = repo_fixture(false)
    output = Path.join(c.root, "new/nested/output")

    {text, rc} = run(@build, [], c.root, c.env ++ required_env(output))

    assert rc == 2
    assert text =~ "output directory must be outside repository"
    refute File.exists?(output)
    refute File.exists?(c.marker)
  end

  test "all inside-repository path spellings refuse before output or mix" do
    c = repo_fixture(false)
    outside = tmp("links")
    link = Path.join(outside, "repo-link")
    File.ln_s!(c.root, link)

    cases = [
      c.root,
      Path.join(c.root, "direct"),
      "relative/output",
      Path.join(c.root, "nested/../lexical-output"),
      Path.join(link, "symlink-parent-output")
    ]

    for {output, index} <- Enum.with_index(cases) do
      {text, rc} = run(@build, [], c.root, c.env ++ required_env(output))
      assert rc == 2, "case #{index}: #{text}"
      assert text =~ "output directory must be outside repository"
      refute File.exists?(c.marker)
      refute File.exists?(Path.join(c.root, "direct"))
      refute File.exists?(Path.join(c.root, "relative"))
      refute File.exists?(Path.join(c.root, "lexical-output"))
      refute File.exists?(Path.join(c.root, "symlink-parent-output"))
    end
  end

  test "ordinary failed tooling retains and reports private artifacts without publishing output" do
    c = repo_fixture(false)
    output = Path.join(tmp("outside-parent"), "new-output")

    {text, rc} = run(@build, [], c.root, c.env ++ required_env(output))

    assert rc == 99, text
    assert File.exists?(c.marker)
    refute File.exists?(output)
    work = retained_path(text, "retained-work-residue")
    private = retained_path(text, "private-last-known-path")
    assert File.dir?(work)
    assert File.dir?(private)
    assert failure_status(text, output, "same-object")
    assert text =~ "private-last-known-path-currently-references-recorded-object=true"
    assert text =~ "future-custody-guaranteed=false"
    assert text =~ "retained-work-residue-owner-only=true"
    assert text =~ "retained-work-residue-published=false"
    assert owner_only_directory?(work)
    assert owner_only_directory?(private)
  end

  test "foreign output created during private output creation is never deleted" do
    c = repo_fixture(false)
    output = Path.join(tmp("creation-race-parent"), "candidate")
    sentinel = Path.join(output, "foreign-sentinel")
    real_mktemp = System.find_executable("mktemp")
    real_mkdir = System.find_executable("mkdir")

    File.write!(
      Path.join(c.fake_bin, "mkdir"),
      """
      #!/usr/bin/env bash
      if [[ $* == *'#{output}'* ]]; then
        '#{real_mkdir}' -p '#{output}'
        printf foreign >'#{sentinel}'
      fi
      exec '#{real_mkdir}' "$@"
      """
    )

    File.write!(
      Path.join(c.fake_bin, "mktemp"),
      """
      #!/usr/bin/env bash
      if [[ $* == *'.spruce-goose-output.'* ]]; then
        mkdir -p '#{output}'
        printf foreign >'#{sentinel}'
      fi
      exec '#{real_mktemp}' "$@"
      """
    )

    for fake <- ["mkdir", "mktemp"], do: File.chmod!(Path.join(c.fake_bin, fake), 0o700)
    git(c.root, ["add", "fake-bin/mkdir", "fake-bin/mktemp"])
    git(c.root, ["commit", "-qm", "creation-race-fixture"])

    {text, rc} = run(@build, [], c.root, c.env ++ required_env(output))

    assert rc == 99, text
    assert File.read!(sentinel) == "foreign"
  end

  test "foreign output substituted after private creation is never deleted" do
    c = repo_fixture(false)
    output = Path.join(tmp("substitution-parent"), "candidate")
    sentinel = Path.join(output, "foreign-sentinel")

    File.write!(
      Path.join(c.fake_bin, "mix"),
      """
      #!/usr/bin/env bash
      private=$(find '#{Path.dirname(output)}' -maxdepth 1 -type d -name '.spruce-goose-output.*' -print -quit)
      target=${private:-'#{output}'}
      mv "$target" "$target-owned-away"
      mkdir -p "$target"
      printf foreign >"$target/foreign-sentinel"
      exit 99
      """
    )

    File.chmod!(Path.join(c.fake_bin, "mix"), 0o700)
    git(c.root, ["add", "fake-bin/mix"])
    git(c.root, ["commit", "-qm", "substitution-fixture"])

    {text, rc} = run(@build, [], c.root, c.env ++ required_env(output))

    foreign =
      Path.dirname(output)
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, ".spruce-goose-output."))
      |> Enum.map(&Path.join([Path.dirname(output), &1, "foreign-sentinel"]))
      |> then(&[sentinel | &1])
      |> Enum.filter(&File.exists?/1)

    assert rc == 99, text
    assert length(foreign) == 1
    replacement = Path.dirname(hd(foreign))
    assert File.read!(hd(foreign)) == "foreign"
    assert failure_status(text, output, "different-object")
    assert retained_path(text, "private-last-known-path") == replacement
    assert retained_path(text, "owned-private-location") == "UNKNOWN"
    assert retained_path(text, "private-current-identity") =~ ~r/^\d+:\d+$/
    refute text =~ "retained-private-output-artifact="
    refute text =~ "owned-private-location=#{replacement}"
  end

  test "symlink replacement after private creation is preserved without following its target" do
    c = repo_fixture(false)
    output = Path.join(tmp("symlink-substitution-parent"), "candidate")
    target = tmp("symlink-substitution-target")
    sentinel = Path.join(target, "foreign-sentinel")
    File.write!(sentinel, "foreign")

    File.write!(
      Path.join(c.fake_bin, "mix"),
      """
      #!/usr/bin/env bash
      private=$(find '#{Path.dirname(output)}' -maxdepth 1 -type d -name '.spruce-goose-output.*' -print -quit)
      mv -- "$private" "$private-owned-away"
      ln -s -- '#{target}' "$private"
      exit 99
      """
    )

    File.chmod!(Path.join(c.fake_bin, "mix"), 0o700)
    git(c.root, ["add", "fake-bin/mix"])
    git(c.root, ["commit", "-qm", "symlink-substitution-fixture"])

    {text, rc} = run(@build, [], c.root, c.env ++ required_env(output))

    assert rc == 99, text
    private = retained_path(text, "private-last-known-path")
    assert File.lstat!(private).type == :symlink
    assert File.read!(sentinel) == "foreign"
    assert failure_status(text, output, "symlink")
    assert retained_path(text, "owned-private-location") == "UNKNOWN"
    refute text =~ "retained-private-output-artifact="
    refute text =~ "owned-private-location=#{private}"
  end

  test "foreign replacement installed after cleanup identity return is preserved" do
    c = repo_fixture(false)
    output = Path.join(tmp("post-stat-substitution-parent"), "candidate")
    barrier = Path.join(tmp("post-stat-substitution-barrier"), "stat-race-fired")
    calls = barrier <> ".calls"
    real_stat = System.find_executable("stat")

    File.write!(
      Path.join(c.fake_bin, "stat"),
      """
      #!/usr/bin/env bash
      target=${!#}
      if [[ $target == *'/.spruce-goose-output.'* ]]; then
        count=0
        [[ ! -f '#{calls}' ]] || count=$(cat '#{calls}')
        count=$((count + 1))
        printf '%s' "$count" >'#{calls}'
        if [[ $count -eq 1 ]]; then
          identity=$('#{real_stat}' "$@") || exit $?
          mv -- "$target" "$target-owned-away"
          mkdir -- "$target"
          printf foreign >"$target/foreign-sentinel"
          printf '%s' "$target" >'#{barrier}'
          printf '%s\n' "$identity"
          exit 0
        fi
      fi
      exec '#{real_stat}' "$@"
      """
    )

    File.chmod!(Path.join(c.fake_bin, "stat"), 0o700)
    git(c.root, ["add", "fake-bin/stat"])
    git(c.root, ["commit", "-qm", "post-stat-substitution-fixture"])

    {text, rc} = run(@build, [], c.root, c.env ++ required_env(output))

    assert File.exists?(barrier), "external stat substitution barrier did not fire: #{text}"
    replaced = File.read!(barrier)
    assert rc == 99, text
    assert File.read!(Path.join(replaced, "foreign-sentinel")) == "foreign"
  end

  test "private directory moved away without replacement is reported absent and unowned" do
    c = repo_fixture(false)
    output = Path.join(tmp("absent-private-parent"), "candidate")

    File.write!(
      Path.join(c.fake_bin, "mix"),
      """
      #!/usr/bin/env bash
      private=$(find '#{Path.dirname(output)}' -maxdepth 1 -type d -name '.spruce-goose-output.*' -print -quit)
      mv -- "$private" "$private-owned-away"
      exit 99
      """
    )

    File.chmod!(Path.join(c.fake_bin, "mix"), 0o700)
    git(c.root, ["add", "fake-bin/mix"])
    git(c.root, ["commit", "-qm", "absent-private-fixture"])

    {text, rc} = run(@build, [], c.root, c.env ++ required_env(output))

    private = retained_path(text, "private-last-known-path")
    moved = private <> "-owned-away"
    assert rc == 99, text
    assert File.dir?(moved)
    refute File.exists?(private)
    assert text =~ "private-current-state=absent"
    assert retained_path(text, "owned-private-location") == "UNKNOWN"
    assert text =~ "published=false"
    assert text =~ "automatic-cleanup-attempted=false"
  end

  test "reporting stat failure preserves primary status and reports unknown ownership" do
    c = repo_fixture(false)
    output = Path.join(tmp("report-stat-failure-parent"), "candidate")
    calls = Path.join(tmp("report-stat-failure-calls"), "stat.calls")
    barrier = calls <> ".report-lookup-ran"
    real_stat = System.find_executable("stat")

    File.write!(
      Path.join(c.fake_bin, "stat"),
      """
      #!/usr/bin/env bash
      target=${!#}
      if [[ $target == *'/.spruce-goose-output.'* ]]; then
        count=0
        [[ ! -f '#{calls}' ]] || count=$(cat '#{calls}')
        count=$((count + 1))
        printf '%s' "$count" >'#{calls}'
        if [[ $count -eq 2 ]]; then
          printf report-lookup-ran >'#{barrier}'
          exit 77
        fi
      fi
      exec '#{real_stat}' "$@"
      """
    )

    File.chmod!(Path.join(c.fake_bin, "stat"), 0o700)
    git(c.root, ["add", "fake-bin/stat"])
    git(c.root, ["commit", "-qm", "report-stat-failure-fixture"])

    {text, rc} = run(@build, [], c.root, c.env ++ required_env(output))

    private = retained_path(text, "private-last-known-path")
    assert rc == 99, text
    assert File.read!(calls) == "2"
    assert File.read!(barrier) == "report-lookup-ran"
    assert File.dir?(private)
    assert text =~ "private-current-state=inspection-error"
    assert retained_path(text, "owned-private-location") == "UNKNOWN"
    assert text =~ "published=false"
    assert text =~ "automatic-cleanup-attempted=false"
  end

  test "stable finalization publishes exactly the requested output path" do
    c = mutating_repo_fixture(:stable)
    output = Path.join(tmp("stable-output-parent"), "candidate")

    {text, rc} = run(@build, [], c.root, c.env ++ required_env(output))

    assert rc == 0, text
    assert text =~ "archive=#{output}/app-0.1.0-governed.tar.gz"
    assert text =~ "receipt=#{output}/app-0.1.0-governed.tar.gz.receipt.json"
    assert File.exists?(Path.join(output, "app-0.1.0-governed.tar.gz"))
    assert File.exists?(Path.join(output, "app-0.1.0-governed.tar.gz.receipt.json"))
    work = retained_path(text, "retained-work-residue")
    assert File.dir?(work)
    assert owner_only_directory?(work)
    assert text =~ "retained-work-residue-owner-only=true"
    assert text =~ "retained-work-residue-published=true"
    assert text =~ "retained-work-residue-run-task=tsk-20260813T111813Z-19e119cb"
    assert text =~ "retained-work-residue-run-transaction=txn"
    assert text =~ "retained-work-residue-cleanup-policy=bounded-governed-cleanup-required"
    refute text =~ "published=false"
    refute text =~ "automatic-cleanup-attempted="
    refute text =~ "private-current-state="
    refute text =~ "retained-private-output-artifact="
    assert owner_only_directory?(output)
    assert owner_only_regular_file?(Path.join(output, "app-0.1.0-governed.tar.gz"))
    assert owner_only_regular_file?(Path.join(output, "app-0.1.0-governed.tar.gz.receipt.json"))
  end

  test "caller-created final output collision refuses publication and preserves sentinel" do
    c = mutating_repo_fixture(:collision)
    output = Path.join(tmp("collision-output-parent"), "candidate")
    sentinel = Path.join(output, "foreign-sentinel")

    {text, rc} = run(@build, [], c.root, c.env ++ required_env(output))

    assert rc == 2, text
    assert text =~ "output directory appeared before publication"
    assert File.read!(sentinel) == "foreign"
    private = retained_path(text, "private-last-known-path")
    assert File.dir?(private)
    assert failure_status(text, output, "same-object")
    assert text =~ "requested-final-path-current-state=present"
  end

  test "mid-build source mutation refuses publication and reports retained artifacts" do
    c = mutating_repo_fixture(:release)
    output = Path.join(tmp("mutation-output-parent"), "candidate")

    {text, rc} = run(@build, [], c.root, c.env ++ required_env(output))

    assert rc == 2, text
    assert text =~ "source changed during build; unpublished private artifacts retained"
    assert File.exists?(c.marker)
    assert File.read!(Path.join(c.root, "tracked")) == "mutated during build\n"
    refute File.exists?(output)
    assert File.dir?(retained_path(text, "retained-work-residue"))
    assert File.dir?(retained_path(text, "private-last-known-path"))
    assert failure_status(text, output, "same-object")
  end

  test "receipt source mutation refuses publication and clean classification" do
    c = mutating_repo_fixture(:receipt)
    output = Path.join(tmp("late-mutation-output-parent"), "candidate")

    {text, rc} = run(@build, [], c.root, c.env ++ required_env(output))
    archives = Path.wildcard(Path.join(output, "*.tar.gz"))
    receipts = Path.wildcard(Path.join(output, "*.receipt.json"))

    observed = """
    rc=#{rc}
    stdout=#{inspect(text)}
    source_status=#{elem(git(c.root, ["status", "--short"]), 0) |> String.trim()}
    tracked=#{inspect(File.read!(Path.join(c.root, "tracked")))}
    output_exists=#{File.exists?(output)}
    archive_count=#{length(archives)}
    receipt_count=#{length(receipts)}
    """

    assert {rc, text =~ "clean-source-candidate", File.read!(Path.join(c.root, "tracked")),
            File.exists?(output), length(archives), length(receipts)} ==
             {2, false, "mutated during receipt\n", false, 0, 0},
           observed

    assert text =~ "source changed during build; unpublished private artifacts retained"
    assert File.dir?(retained_path(text, "retained-work-residue"))
    assert File.dir?(retained_path(text, "private-last-known-path"))
    assert failure_status(text, output, "same-object")
  end

  test "validator refuses missing inventory by default and artifact-only is explicit" do
    commit = String.duplicate("a", 40)
    tree = String.duplicate("b", 40)

    base = [
      "/absent/archive.tar.gz",
      "--receipt",
      "/absent/receipt.json",
      "--expected-commit",
      commit,
      "--expected-tree",
      tree
    ]

    {default_text, default_rc} = run(@validate, base, System.tmp_dir!(), [])
    assert default_rc == 2
    assert default_text =~ "usage: validate-governed-release"

    {artifact_text, artifact_rc} =
      run(@validate, base ++ ["--artifact-only"], System.tmp_dir!(), [])

    assert artifact_rc == 2
    refute artifact_text =~ "destination migration inventory is required"
    assert artifact_text =~ "no such file" or artifact_text =~ "enoent"
  end

  test "validator parser rejects selecting destination inventory and artifact-only together" do
    commit = String.duplicate("a", 40)
    tree = String.duplicate("b", 40)

    args = [
      "/absent/archive.tar.gz",
      "--receipt",
      "/absent/receipt.json",
      "--expected-commit",
      commit,
      "--expected-tree",
      tree,
      "--destination-inventory",
      "/absent/inventory.json",
      "--artifact-only"
    ]

    {text, rc} = run(@validate, args, System.tmp_dir!(), [])

    assert rc == 2
    assert text =~ "usage: validate-governed-release"
    refute text =~ "no such file"
    refute text =~ "enoent"
  end

  test "inspector is boot-free and performs no recursive workspace writes" do
    root = tmp("inspect")
    File.mkdir_p!(Path.join(root, "nested"))
    File.write!(Path.join(root, "nested/existing"), "same\n")
    before = inventory(root)

    {text, rc} =
      run(@inspect, [Path.join(root, "absent.tar.gz")], root, [{"ERL_CRASH_DUMP_SECONDS", "0"}])

    assert rc == 2
    assert text =~ "no such file" or text =~ "enoent"
    assert inventory(root) == before
    refute File.exists?(Path.join(root, "erl_crash.dump"))
  end

  defp mutating_repo_fixture(stage) do
    root = tmp("mutating-build")
    fake_bin = Path.join(root, "fake-bin")
    File.mkdir_p!(fake_bin)
    git(root, ["init", "-q"])
    git(root, ["config", "user.email", "test@example.invalid"])
    git(root, ["config", "user.name", "Test"])
    File.mkdir_p!(Path.join(root, "priv/repo/migrations"))
    File.write!(Path.join(root, "tracked"), "clean\n")
    File.write!(Path.join(root, "priv/repo/migrations/20260101000000_one.exs"), "migration\n")
    marker = Path.join(tmp("mutating-build-marker"), "mix-invoked")

    File.write!(
      Path.join(fake_bin, "mix"),
      """
      #!/usr/bin/env bash
      touch '#{marker}'
      case "$1 $2" in
        "compile --warnings-as-errors") exit 0 ;;
        "run --no-start")
          if [[ "$*" == *'[:app]'* ]]; then printf app; else printf 0.1.0; fi
          exit 0 ;;
        "--version ") printf 'Mix 1.19.5 (compiled with Erlang/OTP 28)\\n'; exit 0 ;;
        "release app")
          while (($#)); do if [[ $1 == --path ]]; then shift; release=$1; fi; shift; done
          mkdir -p "$release/releases/0.1.0"
          printf payload >"$release/bin"
          if [[ '#{stage}' == release ]]; then
            printf 'mutated during build\\n' >'#{Path.join(root, "tracked")}'
          fi
          exit 0 ;;
      esac
      exit 97
      """
    )

    File.write!(
      Path.join(fake_bin, "elixir"),
      """
      #!/usr/bin/env bash
      if [[ $1 == --version ]]; then
        printf 'Elixir 1.19.5 (compiled with Erlang/OTP 28)\\n'
      elif [[ -n ${SG_RECEIPT:-} ]]; then
        printf '{}\\n' >"$SG_RECEIPT"
        if [[ '#{stage}' == receipt ]]; then
          printf 'mutated during receipt\\n' >'#{Path.join(root, "tracked")}'
        elif [[ '#{stage}' == collision ]]; then
          final=${SPRUCE_GOOSE_OUTPUT_DIR%/.spruce-goose-output.*}/candidate
          mkdir -p "$final"
          printf foreign >"$final/foreign-sentinel"
        fi
      else
        printf '{}\\n' >"$SG_PROVENANCE"
      fi
      """
    )

    File.write!(Path.join(fake_bin, "erl"), "#!/usr/bin/env bash\nprintf 28\n")

    for name <- ["mix", "elixir", "erl"], do: File.chmod!(Path.join(fake_bin, name), 0o700)
    git(root, ["add", "."])
    git(root, ["commit", "-qm", "base"])

    %{
      root: root,
      marker: marker,
      env: [{"PATH", fake_bin <> ":" <> System.get_env("PATH")}]
    }
  end

  defp repo_fixture(dirty) do
    root = tmp("build")
    fake_bin = Path.join(root, "fake-bin")
    File.mkdir_p!(fake_bin)
    git(root, ["init", "-q"])
    git(root, ["config", "user.email", "test@example.invalid"])
    git(root, ["config", "user.name", "Test"])
    File.write!(Path.join(root, "tracked"), "clean\n")
    marker = Path.join(root, "mix-invoked")
    fake = Path.join(fake_bin, "mix")
    File.write!(fake, "#!/bin/sh\ntouch '#{marker}'\nexit 99\n")
    File.chmod!(fake, 0o700)
    git(root, ["add", "tracked", "fake-bin/mix"])
    git(root, ["commit", "-qm", "base"])
    if dirty, do: File.write!(Path.join(root, "tracked"), "dirty\n")
    output = Path.join(root, "must-not-exist")

    %{
      root: root,
      fake_bin: fake_bin,
      marker: marker,
      output: output,
      env: [
        {"PATH", fake_bin <> ":" <> System.get_env("PATH")},
        {"SPRUCE_GOOSE_OUTPUT_DIR", output}
      ]
    }
  end

  defp failure_status(text, output, current_state) do
    recorded = retained_path(text, "recorded-private-identity")

    text =~ "published=false" and
      text =~ "automatic-cleanup-attempted=false" and
      text =~ "requested-final-path=#{output}" and
      text =~ "private-current-state=#{current_state}" and
      text =~ "recorded-private-identity=#{recorded}" and
      text =~ "invocation did not publish output to requested final path: #{output}" and
      text =~ "automatic recursive cleanup was not attempted" and
      recorded =~ ~r/^\d+:\d+$/
  end

  defp owner_only_directory?(path) do
    stat = File.stat!(path)
    stat.type == :directory and Bitwise.band(stat.mode, 0o777) == 0o700
  end

  defp owner_only_regular_file?(path) do
    stat = File.stat!(path)
    stat.type == :regular and Bitwise.band(stat.mode, 0o777) == 0o600
  end

  defp retained_path(text, key) do
    [path] = Regex.run(~r/^#{Regex.escape(key)}=(.+)$/m, text, capture: :all_but_first)
    path
  end

  defp required_env(output),
    do: [
      {"SPRUCE_GOOSE_BUILDER", "builder"},
      {"SPRUCE_GOOSE_TASK", "tsk-20260813T111813Z-19e119cb"},
      {"SPRUCE_GOOSE_TRANSACTION", "txn"},
      {"SPRUCE_GOOSE_BUILD_TIME_UTC", "2026-08-13T11:18:13Z"},
      {"SPRUCE_GOOSE_OUTPUT_DIR", output},
      {"SOURCE_DATE_EPOCH", "1786619893"}
    ]

  defp git(root, args), do: System.cmd("git", args, cd: root)

  defp run(command, args, root, env),
    do: System.cmd(command, args, cd: root, env: env, stderr_to_stdout: true)

  defp inventory(root) do
    walk = fn walk, dir ->
      dir
      |> File.ls!()
      |> Enum.sort()
      |> Enum.flat_map(fn name ->
        path = Path.join(dir, name)
        rel = Path.relative_to(path, root)
        stat = File.lstat!(path)

        own = [
          {rel, stat.type, stat.mode, stat.size,
           if(stat.type == :regular, do: :crypto.hash(:sha256, File.read!(path)), else: nil)}
        ]

        if stat.type == :directory, do: own ++ walk.(walk, path), else: own
      end)
    end

    walk.(walk, root)
  end

  defp tmp(label) do
    path = Path.join(System.tmp_dir!(), "spruce-#{label}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end