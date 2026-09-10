ExUnit.start()

defmodule SpruceGoose.ReleaseGateScriptsTest do
  use ExUnit.Case, async: true

  test "dependency refusal and isolated database cleanup scripts" do
    script = Path.expand("release_gate_scripts_test.py", __DIR__)
    {output, status} = System.cmd("python3", [script], stderr_to_stdout: true)
    assert status == 0, output
  end
end
