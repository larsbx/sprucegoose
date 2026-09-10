ExUnit.start()

defmodule SpruceGoose.ReleaseCIPipelineTest do
  use ExUnit.Case, async: true

  @pipeline Path.expand("../.woodpecker.yml", __DIR__)
  @script Path.expand("../scripts/ci-governed-release", __DIR__)

  test "Woodpecker delegates the governed release lane to the repository script" do
    pipeline = File.read!(@pipeline)
    assert pipeline =~ "scripts/ci-governed-release"
    assert pipeline =~ "image: bash"
    assert pipeline =~ "event: push"
    assert pipeline =~ "lfs: false"
    assert pipeline =~ "docker.io/woodpeckerci/plugin-git:2.9.2"
    assert executable?(@script)
  end

  test "CI inspects and validates without activating a release" do
    text = File.read!(@script)
    assert text =~ ~s(scripts/inspect-governed-release "$archive")
    assert text =~ ~s(scripts/validate-governed-release "$archive")
    assert text =~ "--artifact-only"
    refute text =~ "activate-sprucegoose-release"
    refute text =~ "systemctl"
  end

  test "CI refuses dependencies with known security advisories" do
    text = File.read!(@script)
    assert before?(text, "scripts/audit-dependencies", "mix compile --warnings-as-errors")
  end

  test "CI creates, migrates, and removes an isolated pipeline test database" do
    text = File.read!(@script)
    assert text =~ ~s(SPRUCE_GOOSE_TEST_DATABASE="spruce_goose_ci_${ci_db_suffix}")
    assert before?(text, "mix ecto.create", "mix ash.migrate")
    assert before?(text, "mix ash.migrate", "mix test")
    assert text =~ "trap cleanup_test_database EXIT"
    assert text =~ "mix ecto.drop --force --quiet"
  end

  test "CI accounts for workspace writes and preserves any crash before refusing" do
    text = File.read!(@script)
    assert text =~ ~s(export ERL_CRASH_DUMP="$crash" ERL_CRASH_DUMP_SECONDS=0)
    assert text =~ "workspace-before.sha256"
    assert text =~ "workspace-after.sha256"
    assert text =~ ~s(cmp "$evidence/workspace-before.sha256" "$evidence/workspace-after.sha256")
    assert before?(text, ~s(sha256sum "$crash"), "runtime crash dump produced")
  end

  test "review evidence and release output use separate declared paths" do
    text = File.read!(@script)
    assert text =~ "declared-paths.txt"
    assert text =~ "CI evidence must be reviewer-resolvable inside the workspace"
    assert text =~ "release output must be outside the workspace"
  end

  defp executable?(path), do: Bitwise.band(File.stat!(path).mode, 0o111) != 0

  defp before?(text, left, right) do
    case {:binary.match(text, left), :binary.match(text, right)} do
      {{left_index, _}, {right_index, _}} -> left_index < right_index
      _ -> false
    end
  end
end
