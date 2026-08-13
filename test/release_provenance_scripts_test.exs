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
    File.write!(evidence, "governed local evidence only\n")

    env =
      c.env ++
        [{"SPRUCE_GOOSE_ALLOW_DIRTY_EVIDENCE", "1"}, {"SPRUCE_GOOSE_DIRTY_EVIDENCE", evidence}] ++
        required_env(c.output)

    {text, rc} = run(@build, [], c.root, env)
    assert rc == 99, text
    assert text =~ "classification=non-transferable-dirty-evidence"
    assert File.exists?(c.marker)
  end

  test "required build inputs fail with controlled errors before output or tool invocation" do
    c = repo_fixture(false)
    {text, rc} = run(@build, [], c.root, c.env)
    assert rc == 2
    assert text =~ "explicit SPRUCE_GOOSE_BUILDER is required"
    refute File.exists?(c.output)
    refute File.exists?(c.marker)
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

    assert default_text =~
             "destination migration inventory is required; use --artifact-only explicitly"

    {artifact_text, artifact_rc} =
      run(@validate, base ++ ["--artifact-only"], System.tmp_dir!(), [])

    assert artifact_rc == 2
    refute artifact_text =~ "destination migration inventory is required"
    assert artifact_text =~ "no such file" or artifact_text =~ "enoent"
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
      marker: marker,
      output: output,
      env: [
        {"PATH", fake_bin <> ":" <> System.get_env("PATH")},
        {"SPRUCE_GOOSE_OUTPUT_DIR", output}
      ]
    }
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
