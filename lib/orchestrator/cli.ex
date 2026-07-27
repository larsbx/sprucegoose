defmodule Orchestrator.CLI do
  @moduledoc false

  alias Orchestrator.CLI.{Command, Executor}

  def main(args) do
    case run(args) do
      {:ok, output} ->
        IO.puts(Jason.encode!(Map.put(output, :ok, true)))

      {:error, error} ->
        IO.puts(:stderr, Jason.encode!(%{ok: false, error: inspect_error(error)}))
        System.halt(2)
    end
  end

  def run(args) do
    with {:ok, command} <- Command.parse(args), do: Executor.run(command)
  end

  defp inspect_error(:usage),
    do:
      "usage: orchestrator id|validate-id ID|task add OPTIONS TITLE|task show ID|task list [--state STATE]|task propose|queue|ready|start|wait|link|done ID|task cancel ID REASON|task move ID BOARD COLUMN RANK|task metadata ID JSON|todo add|list|done TASK_ID [ARGS]|board add|list [ARGS]|column add|list [ARGS]|filter add|list|apply [ARGS]|inbox add TEXT|inbox list|ledger import|parity PATH"

  defp inspect_error(error) when is_binary(error), do: error
  defp inspect_error(error), do: Exception.message(error)
end
