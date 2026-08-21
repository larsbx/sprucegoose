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
    assert before?(text, "mix hex.audit", "mix compile --warnings-as-errors")
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
  defp before?(text, left, right), do: :binary.match(text, left) < :binary.match(text, right)
end
