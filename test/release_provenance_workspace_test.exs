ExUnit.start()

defmodule SpruceGoose.ReleaseProvenanceWorkspaceTest do
  use ExUnit.Case, async: true

  test "real read-only scripts preserve a recursive before/after workspace inventory" do
    root = Path.join(System.tmp_dir!(), "spruce-workspace-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "nested/deeper"))
    File.write!(Path.join(root, "nested/existing"), "unchanged\n")
    File.write!(Path.join(root, "nested/deeper/existing"), "unchanged too\n")
    before = inventory(root)

    inspect = Path.expand("../scripts/inspect-governed-release", __DIR__)

    {_output, 2} =
      System.cmd(inspect, [Path.join(root, "absent.tar.gz")],
        cd: root,
        stderr_to_stdout: true,
        env: [{"ERL_CRASH_DUMP_SECONDS", "0"}]
      )

    validate = Path.expand("../scripts/validate-governed-release", __DIR__)

    args = [
      Path.join(root, "absent.tar.gz"),
      "--receipt",
      Path.join(root, "absent.json"),
      "--expected-commit",
      String.duplicate("a", 40),
      "--expected-tree",
      String.duplicate("b", 40)
    ]

    {_output, 2} =
      System.cmd(validate, args,
        cd: root,
        stderr_to_stdout: true,
        env: [{"ERL_CRASH_DUMP_SECONDS", "0"}]
      )

    assert inventory(root) == before
    refute File.exists?(Path.join(root, "erl_crash.dump"))
  end

  defp inventory(root) do
    walk = fn walk, directory ->
      directory
      |> File.ls!()
      |> Enum.sort()
      |> Enum.flat_map(fn name ->
        path = Path.join(directory, name)
        stat = File.lstat!(path)

        item =
          {Path.relative_to(path, root), stat.type, stat.mode, stat.size,
           if(stat.type == :regular, do: :crypto.hash(:sha256, File.read!(path)), else: nil)}

        if stat.type == :directory, do: [item | walk.(walk, path)], else: [item]
      end)
    end

    walk.(walk, root)
  end
end
