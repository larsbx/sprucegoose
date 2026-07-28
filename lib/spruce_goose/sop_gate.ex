defmodule SpruceGoose.SopGate do
  @moduledoc false

  @path "/home/admin-papa/.openclaw/vaults/openclaw-system/10-sop/Systemwide SOP.md"

  def path, do: @path

  def acknowledge(@path) do
    with {:ok, body} <- File.read(@path) do
      {:ok,
       %{
         sop_gate_required: true,
         sop_path: @path,
         sop_digest: digest(body),
         sop_acknowledged_at: DateTime.utc_now()
       }}
    else
      {:error, reason} -> {:error, "cannot read canonical Systemwide SOP: #{reason}"}
    end
  end

  def acknowledge(_path), do: {:error, "SOP path must be #{@path}"}

  def verify(%{sop_gate_required: false}), do: :ok

  def verify(%{sop_path: @path, sop_digest: acknowledged_digest}) do
    with {:ok, body} <- File.read(@path) do
      if digest(body) == acknowledged_digest,
        do: :ok,
        else: {:error, "Systemwide SOP acknowledgment is stale; run task acknowledge-sop"}
    else
      {:error, reason} -> {:error, "cannot read canonical Systemwide SOP: #{reason}"}
    end
  end

  def verify(_task), do: {:error, "task has no canonical Systemwide SOP acknowledgment"}

  defp digest(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
