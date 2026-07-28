defmodule SpruceGoose.SopGate do
  @moduledoc false

  @id "systemwide-sop"

  def id, do: @id
  def path, do: Application.fetch_env!(:spruce_goose, :systemwide_sop_path)

  def acknowledge(path) do
    with true <- path == path(),
         {:ok, body} <- File.read(path) do
      {:ok,
       %{
         sop_gate_required: true,
         sop_id: @id,
         sop_path: path,
         sop_digest: digest(body),
         sop_acknowledged_at: DateTime.utc_now()
       }}
    else
      false -> {:error, "SOP path must be #{path()}"}
      {:error, reason} -> {:error, "cannot read configured Systemwide SOP: #{reason}"}
    end
  end

  def verify(%{sop_gate_required: false}), do: :ok

  def verify(%{sop_id: @id, sop_path: acknowledged_path, sop_digest: acknowledged_digest}) do
    configured_path = path()

    with true <- acknowledged_path == configured_path,
         {:ok, body} <- File.read(configured_path) do
      if digest(body) == acknowledged_digest,
        do: :ok,
        else: {:error, "Systemwide SOP acknowledgment is stale; run task acknowledge-sop"}
    else
      false -> {:error, "Systemwide SOP acknowledgment uses the prior configured path"}
      {:error, reason} -> {:error, "cannot read configured Systemwide SOP: #{reason}"}
    end
  end

  def verify(_task), do: {:error, "task has no trusted Systemwide SOP acknowledgment"}

  defp digest(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
