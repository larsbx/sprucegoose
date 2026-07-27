defmodule SpruceGoose.TaskId do
  @moduledoc false

  @pattern ~r/\Atsk-(\d{8}T\d{6}Z)-([0-9a-f]{8})\z/

  def generate(now \\ DateTime.utc_now(), entropy \\ :crypto.strong_rand_bytes(4)) do
    "tsk-" <>
      Calendar.strftime(now, "%Y%m%dT%H%M%SZ") <> "-" <> Base.encode16(entropy, case: :lower)
  end

  def valid?(id), do: match?({:ok, _timestamp}, parse(id))

  def parse(id) when is_binary(id) do
    with [_, timestamp, _entropy] <- Regex.run(@pattern, id),
         {:ok, parsed} <- parse_timestamp(timestamp) do
      {:ok, parsed}
    else
      _ -> {:error, :invalid_task_id}
    end
  end

  def parse(_id), do: {:error, :invalid_task_id}

  defp parse_timestamp(
         <<year::binary-size(4), month::binary-size(2), day::binary-size(2), "T",
           hour::binary-size(2), minute::binary-size(2), second::binary-size(2), "Z">>
       ) do
    with {year, ""} <- Integer.parse(year),
         {month, ""} <- Integer.parse(month),
         {day, ""} <- Integer.parse(day),
         {hour, ""} <- Integer.parse(hour),
         {minute, ""} <- Integer.parse(minute),
         {second, ""} <- Integer.parse(second),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second),
         {:ok, naive} <- NaiveDateTime.new(date, time) do
      DateTime.from_naive(naive, "Etc/UTC")
    else
      _ -> {:error, :invalid_timestamp}
    end
  end
end
