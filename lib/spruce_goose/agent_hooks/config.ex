defmodule SpruceGoose.AgentHooks.Config do
  @moduledoc false
  alias SpruceGoose.Kernel.Canonical

  @charter_path Path.expand("../../../priv/agent_hooks/inbox-triage-v1.json", __DIR__)
  @external_resource @charter_path
  @charter_bytes File.read!(@charter_path)

  def enabled?, do: Application.get_env(:spruce_goose, :inbox_triage_enabled, false)
  def charter, do: Jason.decode!(@charter_bytes)
  def charter_digest, do: digest_bytes(@charter_bytes)

  def current do
    with true <- enabled?(),
         actor_id <- Application.get_env(:spruce_goose, :inbox_triage_actor_id),
         {:ok, ^actor_id} <- Ecto.UUID.cast(actor_id),
         handler <- Application.get_env(:spruce_goose, :inbox_triage_handler),
         :ok <- validate_handler(handler),
         timeout <- Application.get_env(:spruce_goose, :inbox_triage_timeout_ms, 30_000),
         true <- is_integer(timeout) and timeout in 1..300_000 do
      descriptor = %{
        "hook_id" => "inbox-triage",
        "hook_version" => 1,
        "charter_digest" => charter_digest(),
        "actor_id" => actor_id,
        "handler" => Atom.to_string(handler),
        # A VM code stamp detects ordinary adapter changes. It is not a source
        # signature or a cryptographic attestation of third-party code.
        "handler_code_stamp" => Base.encode16(handler.module_info(:md5), case: :lower),
        "timeout_ms" => timeout
      }

      {:ok, %{descriptor: descriptor, digest: digest(descriptor), handler: handler}}
    else
      false -> {:error, :disabled_or_invalid_timeout}
      _ -> {:error, :invalid_hook_configuration}
    end
  end

  def validate_handler(handler) when is_atom(handler) and not is_nil(handler) do
    if Code.ensure_loaded?(handler) and function_exported?(handler, :propose, 1),
      do: :ok,
      else: {:error, "triage handler must export propose/1"}
  end

  def validate_handler(_), do: {:error, "triage handler must export propose/1"}

  def digest(value) do
    {:ok, bytes} = Canonical.encode(value)
    digest_bytes(bytes)
  end

  defp digest_bytes(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
