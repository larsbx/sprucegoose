defmodule SpruceGoose.CLI do
  @moduledoc false

  alias SpruceGoose.CLI.{Command, Executor}

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

  defp inspect_error(:usage), do: "usage: " <> Command.usage()
  defp inspect_error(error) when is_binary(error), do: error
  defp inspect_error(error), do: Exception.message(error)
end
