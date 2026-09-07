defmodule SpruceGoose.CLI.ClientTest do
  use ExUnit.Case, async: true

  @tag timeout: 30_000
  test "the thin client passes offline transport and argument regressions" do
    {output, status} =
      System.cmd(
        "python3",
        ["-B", "-m", "unittest", "discover", "-s", "scripts", "-p", "test_cli_client.py"],
        cd: Path.expand("../..", __DIR__),
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
