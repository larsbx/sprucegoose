defmodule SpruceGoose.TaskId do
  @moduledoc false

  alias SpruceGoose.PrefixedId

  @prefix "tsk"

  def generate(now \\ DateTime.utc_now(), entropy \\ :crypto.strong_rand_bytes(4)),
    do: PrefixedId.generate(@prefix, now, entropy)

  def valid?(id), do: PrefixedId.valid?(@prefix, id)

  def parse(id) do
    case PrefixedId.parse(@prefix, id) do
      {:ok, timestamp} -> {:ok, timestamp}
      {:error, _reason} -> {:error, :invalid_task_id}
    end
  end
end
