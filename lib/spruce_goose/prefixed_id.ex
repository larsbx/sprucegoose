defmodule SpruceGoose.PrefixedId do
  @moduledoc """
  The shared shape of this peer's human-readable record IDs:
  `<prefix>-<YYYYMMDDTHHMMSSZ>-<8 lowercase hex>`.

  `SpruceGoose.TaskId` is the original and its `tsk-` output is a *published*
  contract — the vault write gate regexes against it — so the format lives here
  once and delegates rather than being reimplemented per prefix. A second
  spelling of this format is how the two drift apart.
  """

  @doc "Mint an ID under `prefix`. The stamp and entropy are injectable for tests."
  def generate(prefix, now \\ DateTime.utc_now(), entropy \\ :crypto.strong_rand_bytes(4)) do
    prefix <>
      "-" <>
      Calendar.strftime(now, "%Y%m%dT%H%M%SZ") <> "-" <> Base.encode16(entropy, case: :lower)
  end

  def valid?(prefix, id), do: match?({:ok, _timestamp}, parse(prefix, id))

  def parse(prefix, id) when is_binary(prefix) and is_binary(id) do
    with [_, timestamp, _entropy] <- Regex.run(pattern(prefix), id),
         {:ok, parsed} <- parse_timestamp(timestamp) do
      {:ok, parsed}
    else
      _ -> {:error, :invalid_id}
    end
  end

  def parse(_prefix, _id), do: {:error, :invalid_id}

  defp pattern(prefix), do: ~r/\A#{Regex.escape(prefix)}-(\d{8}T\d{6}Z)-([0-9a-f]{8})\z/

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

  defp parse_timestamp(_timestamp), do: {:error, :invalid_timestamp}
end
