defmodule SpruceGoose.Kernel.Canonical do
  @moduledoc """
  The byte encoding every content identity in the kernel is derived from.

  ## Forms

  `:jcs` (the default since 2026-10-20) is RFC 8785 JSON Canonicalization
  Scheme restricted to the value types the ledger carries: objects with
  string keys, arrays, strings, integers within ±(2^53 − 1), booleans, and
  null. Keys sort by UTF-16 code units, strings escape exactly as ECMAScript
  `JSON.stringify` does, and nothing else is permitted. Floats are refused
  rather than given a convention. The result is a specification that fits on
  a page and is recomputable by any JSON implementation; see
  `scripts/verify-certified-ledger.py` for one that is not the BEAM.

  `:etf` is the legacy form: a version prefix plus Erlang External Term
  Format with `minor_version: 2`. It is kept so that every event written
  before the adoption can still be re-derived and verified, and must not be
  used for new identities.
  """

  @legacy_version "sprucegoose-kernel-v1\0"
  @legacy_options [:deterministic, minor_version: 2]
  @max_safe_integer 9_007_199_254_740_991

  @type form :: :jcs | :etf

  def forms, do: [:jcs, :etf]
  def form_name(:jcs), do: "jcs-v1"
  def form_name(:etf), do: "etf-v1"
  def form_from_name("jcs-v1"), do: {:ok, :jcs}
  def form_from_name("etf-v1"), do: {:ok, :etf}
  def form_from_name(_), do: {:error, :unknown_canonical_form}

  @doc "Canonical bytes of `value` in the default form."
  def encode(value), do: encode(value, :jcs)

  @doc "Canonical bytes of `value` in the named form."
  def encode(value, :jcs) do
    with {:ok, normalized} <- normalize(value), do: jcs(normalized)
  end

  def encode(value, :etf) do
    with {:ok, normalized} <- normalize(value) do
      {:ok, @legacy_version <> :erlang.term_to_binary(normalized, @legacy_options)}
    end
  end

  # --- JCS -----------------------------------------------------------------

  defp jcs(value) do
    {:ok, value |> jcs_iodata() |> IO.iodata_to_binary()}
  catch
    {:noncanonical_value, _} -> {:error, :noncanonical_value}
  end

  defp jcs_iodata(nil), do: "null"
  defp jcs_iodata(true), do: "true"
  defp jcs_iodata(false), do: "false"

  defp jcs_iodata(int) when is_integer(int) and abs(int) <= @max_safe_integer,
    do: Integer.to_string(int)

  defp jcs_iodata(int) when is_integer(int), do: throw({:noncanonical_value, {:integer, int}})
  defp jcs_iodata(bin) when is_binary(bin), do: [?", escape(bin), ?"]

  defp jcs_iodata(list) when is_list(list),
    do: [?[, Enum.map_intersperse(list, ?,, &jcs_iodata/1), ?]]

  defp jcs_iodata({:object, pairs}) do
    pairs
    |> Enum.sort_by(fn {key, _} -> :unicode.characters_to_binary(key, :utf8, {:utf16, :big}) end)
    |> Enum.map_intersperse(?,, fn {key, value} ->
      [?", escape(key), ?", ?:, jcs_iodata(value)]
    end)
    |> then(&[?{, &1, ?}])
  end

  # ECMAScript JSON.stringify escaping: the two delimiters, the five named
  # control characters, every other control character as lowercase \\u00xx,
  # and everything else literal.
  defp escape(bin) do
    for <<codepoint::utf8 <- bin>>, into: <<>> do
      case codepoint do
        ?" ->
          "\\\""

        ?\\ ->
          "\\\\"

        8 ->
          "\\b"

        12 ->
          "\\f"

        10 ->
          "\\n"

        13 ->
          "\\r"

        9 ->
          "\\t"

        c when c < 0x20 ->
          ("\\u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0")) |> String.downcase()

        c ->
          <<c::utf8>>
      end
    end
  end

  # --- normalisation shared by both forms ---------------------------------------

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
