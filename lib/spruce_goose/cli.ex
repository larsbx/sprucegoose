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

  # `--as` is stripped before parsing rather than declared on every verb: each
  # clause parses with `strict:`, so an undeclared flag would be rejected by
  # whichever verb it landed on. Pulling it out once keeps it genuinely global.
  def run(args) do
    {actor_name, args} = Command.extract_actor(args)

    case args do
      ["release", verb | _] when verb in ["inspect-provenance", "validate-provenance"] ->
        with {:ok, command} <- Command.parse(args), do: Executor.run_read_only(command)

      _ ->
        with :ok <- SpruceGoose.AuthorityRuntime.ensure_local_execution_allowed(),
             {:ok, command} <- Command.parse(args),
             do: Executor.run(command, actor_name)
    end
  end

  defp inspect_error(:usage), do: "usage: " <> Command.usage()
  defp inspect_error(error) when is_binary(error), do: error
  defp inspect_error(error), do: Exception.message(error)
end