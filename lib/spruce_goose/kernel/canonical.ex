defmodule SpruceGoose.Kernel.Canonical do
  @moduledoc false

  @version "sprucegoose-kernel-v1\0"

  def encode(value) do
    with {:ok, normalized} <- normalize(value) do
      {:ok, @version <> :erlang.term_to_binary(normalized, [:deterministic])}
    end
  end

  defp normalize(value) when is_binary(value) or is_boolean(value) or is_nil(value),
    do: {:ok, value}

  defp normalize(value) when is_integer(value), do: {:ok, value}

  defp normalize(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, items} ->
      case normalize(item) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | items]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end)
  end

  defp normalize(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn
      {key, item}, {:ok, pairs} when is_binary(key) ->
        case normalize(item) do
          {:ok, normalized} -> {:cont, {:ok, [{key, normalized} | pairs]}}
          error -> {:halt, error}
        end

      _, _acc ->
        {:halt, {:error, :noncanonical_value}}
    end)
    |> then(fn
      {:ok, pairs} -> {:ok, {:object, Enum.sort_by(pairs, &elem(&1, 0))}}
      error -> error
    end)
  end

  defp normalize(_value), do: {:error, :noncanonical_value}
end
