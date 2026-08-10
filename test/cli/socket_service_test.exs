defmodule SpruceGoose.CLI.SocketServiceTest do
  use ExUnit.Case, async: true

  test "the thin client reaches a concurrent Bandit Unix-socket service" do
    %{config: config, env: authority_env} = sop_preflight_fixture("canonical bytes")

    socket_path =
      Path.join(System.tmp_dir!(), "sprucegoose-#{System.unique_integer([:positive])}.sock")

    supervisor = start_supervised!(Task.Supervisor)

    runner = fn
      ["version"] -> {:ok, %{version: "socket-test"}}
      _ -> {:error, "unexpected command"}
    end

    start_supervised!(
      {Bandit,
       plug: {SpruceGoose.CLI.SocketPlug, runner: runner, supervisor: supervisor, timeout: 100},
       scheme: :http,
       ip: {:local, socket_path},
       port: 0,
       startup_log: false}
    )

    on_exit(fn -> File.rm(socket_path) end)

    {output, status} =
      System.cmd("python3", ["scripts/sprucegoose-client.py", "version"],
        env:
          authority_env ++
            [
              {"SPRUCE_GOOSE_SOP_AUTHORITY_CONFIG", config},
              {"SPRUCE_GOOSE_CLI_SOCKET", socket_path}
            ]
      )

    assert status == 0
    assert Jason.decode!(output) == %{"ok" => true, "version" => "socket-test"}
  end

  test "the thin client fails fast when the service is unavailable" do
    %{config: config, env: authority_env} = sop_preflight_fixture("canonical bytes")

    socket_path =
      Path.join(
        System.tmp_dir!(),
        "missing-sprucegoose-#{System.unique_integer([:positive])}.sock"
      )

    started_at = System.monotonic_time(:millisecond)

    {output, status} =
      System.cmd("python3", ["scripts/sprucegoose-client.py", "version"],
        env:
          authority_env ++
            [
              {"SPRUCE_GOOSE_SOP_AUTHORITY_CONFIG", config},
              {"SPRUCE_GOOSE_CLI_SOCKET", socket_path}
            ],
        stderr_to_stdout: true
      )

    assert status == 2
    assert System.monotonic_time(:millisecond) - started_at < 500
    assert Jason.decode!(output)["error"] =~ "service unavailable"
  end

  test "the thin client refuses before socket access when the default authority policy is missing" do
    home =
      Path.join(
        System.tmp_dir!(),
        "sprucegoose-missing-policy-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf(home) end)

    {output, status} =
      System.cmd("python3", ["scripts/sprucegoose-client.py", "version"],
        env: [
          {"HOME", home},
          {"SPRUCE_GOOSE_CLI_SOCKET", "/definitely/missing/sprucegoose.sock"}
        ],
        stderr_to_stdout: true
      )

    assert status == 2
    assert Jason.decode!(output)["error"] =~ "authority policy is unavailable"
    refute output =~ "service unavailable"
  end

  test "the thin client refuses before socket access when canonical and authority SOP bytes differ" do
    %{config: config, env: env} = sop_preflight_fixture("different authority bytes")

    {output, status} =
      System.cmd("python3", ["scripts/sprucegoose-client.py", "version"],
        env:
          env ++
            [
              {"SPRUCE_GOOSE_SOP_AUTHORITY_CONFIG", config},
              {"SPRUCE_GOOSE_CLI_SOCKET", "/definitely/missing/sprucegoose.sock"}
            ],
        stderr_to_stdout: true
      )

    assert status == 2
    assert Jason.decode!(output)["error"] =~ "Systemwide SOP authority mismatch"
    refute output =~ "service unavailable"
  end

  test "the thin client reaches the socket when canonical and authority SOP digests match" do
    %{config: config, env: env} = sop_preflight_fixture("canonical bytes")

    socket_path =
      Path.join(
        System.tmp_dir!(),
        "sprucegoose-preflight-#{System.unique_integer([:positive])}.sock"
      )

    supervisor = start_supervised!(Task.Supervisor)
    runner = fn ["version"] -> {:ok, %{version: "preflight-pass"}} end

    start_supervised!(
      {Bandit,
       plug: {SpruceGoose.CLI.SocketPlug, runner: runner, supervisor: supervisor, timeout: 100},
       scheme: :http,
       ip: {:local, socket_path},
       port: 0,
       startup_log: false}
    )

    on_exit(fn -> File.rm(socket_path) end)

    {output, status} =
      System.cmd("python3", ["scripts/sprucegoose-client.py", "version"],
        env:
          env ++
            [
              {"SPRUCE_GOOSE_SOP_AUTHORITY_CONFIG", config},
              {"SPRUCE_GOOSE_CLI_SOCKET", socket_path}
            ]
      )

    assert status == 0
    assert Jason.decode!(output) == %{"ok" => true, "version" => "preflight-pass"}
  end

  test "the SOP publisher service invokes the installed script through Python" do
    unit = File.read!("ops/mama-authority/sprucegoose-sop-authority-sync.service")
    readme = File.read!("ops/mama-authority/README.md")
    installed = "/home/admin-papa/.local/libexec/sprucegoose-sop-publish.py"

    assert unit =~ "ExecStart=/usr/bin/python3 #{installed}"
    assert readme =~ "install -m 0644 scripts/sprucegoose-sop-publish.py"
    assert readme =~ ~s("$HOME/.local/libexec/sprucegoose-sop-publish.py")

    assert readme =~
             ~s(ssh mama 'sha256sum -- "/home/admin-papa/.openclaw/vaults/openclaw-system/10-sop/Systemwide SOP.md"')
  end

  test "the SOP publisher transfers canonical bytes and verifies the authority digest" do
    root =
      Path.join(System.tmp_dir!(), "sprucegoose-publish-#{System.unique_integer([:positive])}")

    fake_bin = Path.join(root, "bin")
    canonical = Path.join(root, "Systemwide SOP.md")
    authority = Path.join(root, "authority SOP.md")
    config = Path.join(root, "authority.json")
    File.mkdir_p!(fake_bin)
    File.write!(canonical, "published canonical bytes")

    File.write!(
      Path.join(fake_bin, "ssh"),
      "#!/bin/sh\nfor command do :; done\nexec sh -c \"$command\"\n"
    )

    File.chmod!(Path.join(fake_bin, "ssh"), 0o755)

    File.write!(
      config,
      Jason.encode!(%{
        canonical_path: canonical,
        authority_host: "mama",
        authority_path: authority
      })
    )

    on_exit(fn -> File.rm_rf(root) end)

    {output, status} =
      System.cmd("python3", ["scripts/sprucegoose-sop-publish.py"],
        env: [
          {"PATH", fake_bin <> ":" <> System.get_env("PATH")},
          {"SPRUCE_GOOSE_SOP_AUTHORITY_CONFIG", config}
        ],
        stderr_to_stdout: true
      )

    assert status == 0
    assert Jason.decode!(output)["ok"]
    assert File.read!(authority) == "published canonical bytes"
    assert Bitwise.band(File.stat!(authority).mode, 0o777) == 0o600
  end

  test "the SOP publisher refuses same-size mutation and pathname replacement during snapshot" do
    root =
      Path.join(
        System.tmp_dir!(),
        "sprucegoose-publish-race-#{System.unique_integer([:positive])}"
      )

    canonical = Path.join(root, "Systemwide SOP.md")
    File.mkdir_p!(root)
    File.write!(canonical, String.duplicate("a", 131_072))
    on_exit(fn -> File.rm_rf(root) end)

    harness = ~S'''
    import importlib.util, os, sys, time
    path, mode = sys.argv[1], sys.argv[2]
    spec = importlib.util.spec_from_file_location("publisher", "scripts/sprucegoose-sop-publish.py")
    publisher = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(publisher)
    original_read = publisher.os.read
    changed = False
    def racing_read(fd, length):
        global changed
        data = original_read(fd, length)
        if data and not changed:
            changed = True
            time.sleep(0.01)
            if mode == "in_place":
                with open(path, "r+b") as target:
                    target.seek(0)
                    target.write(b"b")
                    target.flush()
                    os.fsync(target.fileno())
            else:
                replacement = path + ".replacement"
                with open(replacement, "wb") as target:
                    target.write(b"b" + b"a" * (131_072 - 1))
                    target.flush()
                    os.fsync(target.fileno())
                os.replace(replacement, path)
        return data
    publisher.os.read = racing_read
    publisher.canonical_bytes(path)
    '''

    for mode <- ["in_place", "replace"] do
      File.write!(canonical, String.duplicate("a", 131_072))

      {output, status} =
        System.cmd("python3", ["-c", harness, canonical, mode], stderr_to_stdout: true)

      assert status == 2
      assert Jason.decode!(output)["error"] =~ "changed during publication"
    end
  end

  defp sop_preflight_fixture(remote_body) do
    root = Path.join(System.tmp_dir!(), "sprucegoose-sop-#{System.unique_integer([:positive])}")
    fake_bin = Path.join(root, "bin")
    canonical = Path.join(root, "Systemwide SOP.md")
    authority = Path.join(root, "authority/Systemwide SOP.md")
    config = Path.join(root, "authority.json")
    File.mkdir_p!(fake_bin)
    File.mkdir_p!(Path.dirname(authority))
    File.write!(canonical, "canonical bytes")
    File.write!(authority, remote_body)

    File.write!(
      Path.join(fake_bin, "ssh"),
      "#!/bin/sh\nfor command do :; done\nexec sh -c \"$command\"\n"
    )

    File.chmod!(Path.join(fake_bin, "ssh"), 0o755)

    File.write!(
      config,
      Jason.encode!(%{
        canonical_path: canonical,
        authority_host: "mama",
        authority_path: authority
      })
    )

    on_exit(fn -> File.rm_rf(root) end)

    %{
      config: config,
      env: [{"PATH", fake_bin <> ":" <> System.get_env("PATH")}]
    }
  end
end
