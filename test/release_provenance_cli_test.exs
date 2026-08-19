ExUnit.start()

Code.require_file("../lib/spruce_goose/cli/command.ex", __DIR__)

defmodule SpruceGoose.AuthorityRuntime do
  def ensure_local_execution_allowed, do: raise("AUTHORITY_RUNTIME_CALLED")
end

defmodule SpruceGoose.CLI.Executor do
  def run_read_only(command) do
    send(self(), {:read_only_executed, command})
    {:ok, %{command: command}}
  end

  def run(_command, _actor), do: raise("MUTATING_EXECUTOR_CALLED")
end

Code.require_file("../lib/spruce_goose/cli.ex", __DIR__)

defmodule SpruceGoose.ReleaseProvenanceCLITest do
  use ExUnit.Case, async: false

  @commit String.duplicate("a", 40)
  @tree String.duplicate("b", 40)

  test "real Command parses release inspection and help advertises it" do
    assert {:ok, {:inspect_release_provenance, "/tmp/release.tar.gz"}} =
             SpruceGoose.CLI.Command.parse([
               "release",
               "inspect-provenance",
               "/tmp/release.tar.gz"
             ])

    assert "inspect-provenance ARCHIVE" in SpruceGoose.CLI.Command.help("release").forms
  end

  test "real CLI.run executes release inspection before authority runtime or actor resolution" do
    assert {:ok, %{command: {:inspect_release_provenance, "/tmp/release.tar.gz"}}} =
             SpruceGoose.CLI.run([
               "release",
               "inspect-provenance",
               "/tmp/release.tar.gz"
             ])

    assert_received {:read_only_executed, {:inspect_release_provenance, "/tmp/release.tar.gz"}}
  end

  test "real CLI.run executes release validation before authority runtime or actor resolution" do
    args = [
      "release",
      "validate-provenance",
      "/tmp/release.tar.gz",
      "--receipt",
      "/tmp/receipt.json",
      "--expected-commit",
      @commit,
      "--expected-tree",
      @tree,
      "--artifact-only"
    ]

    assert {:ok, %{command: {:validate_release_provenance, "/tmp/release.tar.gz", opts}}} =
             SpruceGoose.CLI.run(args)

    assert opts[:receipt] == "/tmp/receipt.json"
    assert opts[:expected_commit] == @commit
    assert opts[:expected_tree] == @tree
    assert opts[:artifact_only]

    assert_received {:read_only_executed,
                     {:validate_release_provenance, "/tmp/release.tar.gz", ^opts}}
  end
end