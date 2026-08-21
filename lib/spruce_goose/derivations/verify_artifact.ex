defmodule SpruceGoose.Derivations.VerifyArtifact do
  @moduledoc "Verify one content-addressed input and store deterministic evidence."

  alias SpruceGoose.Artifacts.Store
  alias SpruceGoose.Derivations.Permit

  def run(%Permit{action: :verify_artifact, input_artifact_digest: digest} = permit) do
    with {:ok, _input} <- Store.verify(digest),
         {:ok, evidence} <- Store.put_bytes(evidence(permit)) do
      {:ok, %{evidence_digest: evidence.digest, artifact_digest: digest}}
    end
  end

  def run(%Permit{}), do: {:error, "verify_artifact handler received the wrong action"}

  defp evidence(permit) do
    [
      "sprucegoose-derivation-evidence-v1\n",
      "action=verify_artifact\n",
      "permit_id=",
      permit.permit_id,
      "\n",
      "repository=",
      permit.repository,
      "\n",
      "commit_sha=",
      permit.commit_sha,
      "\n",
      "input_artifact_digest=",
      permit.input_artifact_digest,
      "\n",
      "result=verified\n"
    ]
    |> IO.iodata_to_binary()
  end
end
