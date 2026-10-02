defmodule SpruceGoose.AgentHooks.Proposal do
  @moduledoc "Exact, bounded data schema for advisory inbox triage output."

  @keys ~w(disposition project_key workflow_key rationale uncertainty evidence_refs draft_task_definition)
  @draft_keys ~w(title description task_type task_kind acceptance_criteria)
  @key ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/

  def validate(value) do
    with true <- exact_keys?(value, @keys),
         true <- value["disposition"] in ~w(drop resolve draft_task_definition),
         true <- optional_key?(value["project_key"]) and optional_key?(value["workflow_key"]),
         true <- text?(value["rationale"], 4_000),
         true <- value["uncertainty"] in ~w(low moderate high),
         true <- texts?(value["evidence_refs"], 16, 512),
         true <- valid_draft?(value),
         {:ok, encoded} <- Jason.encode(value),
         true <- byte_size(encoded) <= 16_384 do
      :ok
    else
      _ -> {:error, "proposal must match the exact bounded inbox-triage schema"}
    end
  end

  defp valid_draft?(%{"disposition" => "draft_task_definition", "draft_task_definition" => draft}) do
    exact_keys?(draft, @draft_keys) and text?(draft["title"], 200) and
      text?(draft["description"], 8_000) and draft["task_type"] in ~w(task diagnosis) and
      draft["task_kind"] in ~w(oban taskflow openclaw) and
      texts?(draft["acceptance_criteria"], 16, 1_000) and draft["acceptance_criteria"] != []
  end

  defp valid_draft?(value), do: is_nil(value["draft_task_definition"])
  defp optional_key?(nil), do: true

  defp optional_key?(value),
    do: is_binary(value) and String.valid?(value) and Regex.match?(@key, value)

  defp exact_keys?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp text?(value, max),
    do:
      is_binary(value) and String.valid?(value) and String.trim(value) != "" and
        String.length(value) <= max

  defp texts?(value, count, max),
    do: is_list(value) and length(value) <= count and Enum.all?(value, &text?(&1, max))
end
