defmodule SpruceGoose.Deployment.HostAdapter.Scripted do
  @moduledoc """
  Host adapter over the existing `activate-sprucegoose-release` script.

  The script is the small, separately runnable component: it validates the
  archive against its receipt and the destination migration inventory, stages,
  activates, and restores the previous release on a failed restart, and it
  works with SpruceGoose down. This adapter only assembles its arguments from
  identities in the operation request and reads back what it left on disk.

  Closed argument construction: every path comes from static configuration or
  from the release's own receipt; the request supplies identities only. The
  operation ID is the script's `--task`, so the activation record, rollback
  slot, and confirmation token all name the operation, and a repeated run of
  the same operation is refused by the script's own "record already exists"
  check.

  Configuration (`:deployment_scripted_adapter`):

      %{
        script: "/path/to/scripts/activate-sprucegoose-release",
        archive_dir: "/path/to/archives",   # <hex>.receipt.json and the receipt's filename
        install_dir: "/path/to/install",
        records_dir: "/path/to/activation-records",
        inventory: "/path/to/destination-migration-inventory",
        target: "mama"
      }
  """

  @behaviour SpruceGoose.Deployment.HostAdapter

  alias SpruceGoose.Artifacts.Store

  @required ~w(script archive_dir install_dir records_dir inventory target)a
  @max_detail 4_000

  @impl true
  def execute(%{action: :execute_reclaim}), do: {:error, "reclaim has no host activation; refuse"}

  def execute(request) do
    with {:ok, config} <- config(),
         {:ok, argv} <- command(request, config) do
      case System.cmd(config.script, argv, stderr_to_stdout: true, env: []) do
        {output, 0} -> {:ok, %{evidence_digest: evidence(output), detail: truncate(output)}}
        {output, status} -> {:error, "exit #{status}: #{truncate(output)}"}
      end
    end
  end

  @impl true
  def observe(%{operation_id: operation_id}) do
    with {:ok, config} <- config() do
      record = record_path(config, operation_id)
      failed = "#{config.install_dir}.failed-#{operation_id}"

      cond do
        File.regular?(record) and File.dir?(failed) ->
          {:ok,
           %{
             status: :failed,
             detail: "activation record present; failed release set aside at #{failed}"
           }}

        File.regular?(record) ->
          case read_json(record) do
            {:ok, %{"task" => ^operation_id}} ->
              {:ok, %{status: :succeeded, detail: "activation record #{record}"}}

            _ ->
              {:ok, %{status: :unknown, detail: "activation record does not name this operation"}}
          end

        staging?(config) ->
          {:ok, %{status: :in_progress, detail: "release staging directory present"}}

        true ->
          {:ok, %{status: :unknown, detail: "no activation record for #{operation_id}"}}
      end
    end
  end

  @doc """
  The exact argument vector for one request: pure, so it can be inspected and
  tested without a host. Reads the release receipt to bind the archive
  filename and source tree, and refuses a receipt that disagrees with the
  release identity.
  """
  def command(%{action: action, operation_id: operation_id} = request, config)
      when action in [:execute_deploy, :execute_rollback] do
    release = if action == :execute_deploy, do: request.release, else: request.target.release

    with {:ok, hex} <- archive_hex(release),
         {:ok, receipt} <- receipt(config, hex),
         :ok <- consistent(receipt, release, hex),
         {:ok, previous} <- previous_record(action, request, config) do
      {:ok,
       [
         mode(action),
         "--target",
         config.target,
         "--release-archive",
         Path.join(config.archive_dir, receipt["archive"]["filename"]),
         "--receipt",
         receipt_path(config, hex),
         "--expected-commit",
         receipt["source"]["commit"],
         "--expected-tree",
         receipt["source"]["tree"],
         "--destination-inventory",
         config.inventory,
         "--install-dir",
         config.install_dir,
         "--activation-record",
         record_path(config, operation_id),
         "--task",
         operation_id
       ] ++
         previous ++
         ["--activate", "--confirm-activation", "ACTIVATE:#{config.target}:#{operation_id}"]}
    end
  end

  def command(_request, _config), do: {:error, "unsupported action for the scripted adapter"}

  defp mode(:execute_deploy), do: "deploy"
  defp mode(:execute_rollback), do: "rollback"

  defp previous_record(:execute_deploy, _request, _config), do: {:ok, []}

  defp previous_record(:execute_rollback, %{target: %{operation_id: activation}}, config)
       when is_binary(activation),
       do:
         {:ok,
          [
            "--previous-activation-record",
            record_path(config, activation),
            "--reason",
            "rollback of failed release"
          ]}

  defp previous_record(:execute_rollback, _request, _config),
    do: {:error, "rollback target has no recorded activation operation"}

  defp archive_hex(%{"artifacts" => %{"archive" => "sha256:" <> hex}}), do: {:ok, hex}
  defp archive_hex(_release), do: {:error, "release carries no archive digest"}

  # The receipt is decoded through the governed codec, so a malformed or
  # noncanonical receipt is refused before any path is derived from it.
  defp receipt(config, hex) do
    path = receipt_path(config, hex)

    with {:ok, bytes} <- File.read(path) |> file_error(path) do
      SpruceGoose.ReleaseProvenance.decode_receipt(bytes)
    end
  end

  defp file_error({:ok, bytes}, _path), do: {:ok, bytes}
  defp file_error({:error, reason}, path), do: {:error, "cannot read #{path}: #{reason}"}

  defp consistent(receipt, release, hex) do
    cond do
      receipt["archive"]["sha256"] != hex ->
        {:error, "receipt archive digest does not match the release"}

      receipt["source"]["commit"] != release["source_commit"] ->
        {:error, "receipt commit does not match the release"}

      true ->
        :ok
    end
  end

  defp receipt_path(config, hex), do: Path.join(config.archive_dir, hex <> ".receipt.json")

  defp record_path(config, operation_id),
    do: Path.join(config.records_dir, operation_id <> ".json")

  defp staging?(config) do
    config.install_dir
    |> Path.dirname()
    |> Path.join(".sprucegoose-stage.*")
    |> Path.wildcard(match_dot: true) !=
      []
  end

  defp read_json(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(bytes) do
      {:ok, decoded}
    else
      {:error, reason} when is_atom(reason) -> {:error, "cannot read #{path}: #{reason}"}
      _ -> {:error, "#{path} is not a JSON object"}
    end
  end

  # The script's output is the evidence; keep it in custody when a store exists.
  defp evidence(output) do
    case Application.get_env(:spruce_goose, :artifact_store_root) do
      nil ->
        :crypto.hash(:sha256, output) |> Base.encode16(case: :lower)

      _root ->
        with({:ok, %{digest: digest}} <- Store.put_bytes(output), do: digest)
        |> then(&if(is_binary(&1), do: &1, else: nil))
    end
  end

  defp truncate(output), do: String.slice(output, 0, @max_detail)

  defp config do
    case Application.get_env(:spruce_goose, :deployment_scripted_adapter) do
      %{} = config ->
        if Enum.all?(@required, &(is_binary(Map.get(config, &1)) and Map.get(config, &1) != "")),
          do: {:ok, config},
          else: {:error, "scripted adapter configuration is incomplete"}

      _ ->
        {:error, "scripted adapter is not configured"}
    end
  end
end
