defmodule SpruceGoose.Deployment.HostAdapter.ScriptedTest do
  use ExUnit.Case, async: false

  alias SpruceGoose.Deployment.HostAdapter.Scripted
  alias SpruceGoose.ReleaseProvenance

  @hex String.duplicate("1", 64)
  @commit String.duplicate("a", 40)
  @tree String.duplicate("b", 40)

  setup do
    root =
      Path.join(System.tmp_dir!(), "sprucegoose-scripted-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "archives"))
    File.mkdir_p!(Path.join(root, "records"))
    File.mkdir_p!(Path.join(root, "install"))
    on_exit(fn -> File.rm_rf!(root) end)

    config = %{
      script: Path.join(root, "activate"),
      archive_dir: Path.join(root, "archives"),
      install_dir: Path.join(root, "install/sprucegoose"),
      records_dir: Path.join(root, "records"),
      inventory: Path.join(root, "inventory"),
      target: "mama"
    }

    receipt = %{
      "schema" => ReleaseProvenance.receipt_schema(),
      "archive" => %{"filename" => "spruce_goose-1.tar.xz", "sha256" => @hex, "size_bytes" => 10},
      "build_time_utc" => "2026-09-10T12:00:00Z",
      "elixir_version" => "1.19.5",
      "otp_version" => "28.3.1",
      "migration_set_sha256" => String.duplicate("c", 64),
      "provenance_sha256" => String.duplicate("d", 64),
      "source" => %{"commit" => @commit, "tree" => @tree}
    }

    {:ok, bytes} = ReleaseProvenance.encode_receipt(receipt)
    File.write!(Path.join(config.archive_dir, @hex <> ".receipt.json"), bytes)
    {:ok, config: config}
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: "dpo-" <> String.duplicate("9", 64),
        action: :execute_deploy,
        deployment_id: "dpl-20260910T120000Z-00000001",
        environment: :production,
        release: %{"source_commit" => @commit, "artifacts" => %{"archive" => "sha256:" <> @hex}},
        target: nil
      },
      overrides
    )
  end

  test "deploy arguments are closed, path-bound to configuration and the receipt, and name the operation",
       %{config: config} do
    assert {:ok, argv} = Scripted.command(request(), config)
    id = request().operation_id

    assert argv == [
             "deploy",
             "--target",
             "mama",
             "--release-archive",
             Path.join(config.archive_dir, "spruce_goose-1.tar.xz"),
             "--receipt",
             Path.join(config.archive_dir, @hex <> ".receipt.json"),
             "--expected-commit",
             @commit,
             "--expected-tree",
             @tree,
             "--destination-inventory",
             config.inventory,
             "--install-dir",
             config.install_dir,
             "--activation-record",
             Path.join(config.records_dir, id <> ".json"),
             "--task",
             id,
             "--activate",
             "--confirm-activation",
             "ACTIVATE:mama:" <> id
           ]
  end

  test "rollback re-applies the target's archive against the target's activation record", %{
    config: config
  } do
    target = %{
      deployment_id: "dpl-target",
      operation_id: "dpo-" <> String.duplicate("8", 64),
      release: request().release
    }

    assert {:ok, argv} =
             Scripted.command(request(%{action: :execute_rollback, target: target}), config)

    assert hd(argv) == "rollback"
    assert "--previous-activation-record" in argv
    assert Path.join(config.records_dir, target.operation_id <> ".json") in argv
    assert "--reason" in argv

    assert {:error, reason} =
             Scripted.command(
               request(%{action: :execute_rollback, target: Map.delete(target, :operation_id)}),
               config
             )

    assert reason =~ "no recorded activation"
  end

  test "a receipt that disagrees with the release, or a release without an archive, is refused",
       %{config: config} do
    assert {:error, reason} =
             Scripted.command(
               request(%{
                 release: %{
                   "source_commit" => String.duplicate("f", 40),
                   "artifacts" => %{"archive" => "sha256:" <> @hex}
                 }
               }),
               config
             )

    assert reason =~ "commit"

    assert {:error, reason} =
             Scripted.command(
               request(%{
                 release: %{
                   "source_commit" => @commit,
                   "artifacts" => %{"image" => "sha256:" <> @hex}
                 }
               }),
               config
             )

    assert reason =~ "no archive"

    assert {:error, reason} =
             Scripted.command(
               request(%{
                 release: %{
                   "source_commit" => @commit,
                   "artifacts" => %{"archive" => "sha256:" <> String.duplicate("2", 64)}
                 }
               }),
               config
             )

    assert reason =~ "cannot read"

    assert {:error, _} = Scripted.command(request(%{action: :execute_reclaim}), config)
  end

  test "observation reads only what the script leaves on disk", %{config: config} do
    previous = Application.get_env(:spruce_goose, :deployment_scripted_adapter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spruce_goose, :deployment_scripted_adapter, previous),
        else: Application.delete_env(:spruce_goose, :deployment_scripted_adapter)
    end)

    Application.put_env(:spruce_goose, :deployment_scripted_adapter, config)
    id = request().operation_id

    assert {:ok, %{status: :unknown}} = Scripted.observe(request())

    File.mkdir_p!(Path.join(Path.dirname(config.install_dir), ".sprucegoose-stage.abc"))
    assert {:ok, %{status: :in_progress}} = Scripted.observe(request())

    record = Path.join(config.records_dir, id <> ".json")

    File.write!(
      record,
      Jason.encode!(%{"schema" => "spruce-goose-activation-v1", "task" => "someone-else"})
    )

    assert {:ok, %{status: :unknown}} = Scripted.observe(request())

    File.write!(record, Jason.encode!(%{"schema" => "spruce-goose-activation-v1", "task" => id}))
    assert {:ok, %{status: :succeeded}} = Scripted.observe(request())

    File.mkdir_p!("#{config.install_dir}.failed-#{id}")
    assert {:ok, %{status: :failed}} = Scripted.observe(request())

    Application.delete_env(:spruce_goose, :deployment_scripted_adapter)
    assert {:error, "scripted adapter is not configured"} = Scripted.observe(request())
    assert {:error, "scripted adapter is not configured"} = Scripted.execute(request())
  end

  test "execute runs the configured script with the closed argument vector and returns its output as evidence",
       %{config: config} do
    previous = Application.get_env(:spruce_goose, :deployment_scripted_adapter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spruce_goose, :deployment_scripted_adapter, previous),
        else: Application.delete_env(:spruce_goose, :deployment_scripted_adapter)
    end)

    Application.put_env(:spruce_goose, :deployment_scripted_adapter, config)

    File.write!(
      config.script,
      "#!/usr/bin/env bash\nprintf 'argv=%s\\n' \"$*\"\n[[ $1 == deploy ]] || exit 3\n"
    )

    File.chmod!(config.script, 0o700)

    assert {:ok, %{detail: detail, evidence_digest: digest}} = Scripted.execute(request())
    assert detail =~ "--task " <> request().operation_id
    assert byte_size(digest) == 64

    assert {:error, reason} =
             Scripted.execute(
               request(%{
                 action: :execute_rollback,
                 target: %{
                   deployment_id: "t",
                   operation_id: "dpo-" <> String.duplicate("7", 64),
                   release: request().release
                 }
               })
             )

    assert reason =~ "exit 3"
  end
end
