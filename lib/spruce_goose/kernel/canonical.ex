defmodule SpruceGoose.Kernel.Canonical do
  @moduledoc """
  The byte encoding every content identity in the kernel is derived from.

  ## What this guarantees, and what it does not

  Normalization is strict: binary keys only, maps flattened to sorted
  `{:object, pairs}` tuples, and floats, atoms, and structs refused outright. So
  the same value always reaches `term_to_binary/2` in the same shape, and the
  ambiguous types are excluded rather than given a convention.

  What is hashed after that is Erlang External Term Format. `:deterministic`
  fixes ordering within a given ERTS, and `minor_version: 2` pins the encoding
  variant — without it, the variant is whatever the runtime defaults to, which
  is not a property of this module. That makes identities stable across OTP
  releases for a fixed minor version, which is the guarantee the ledger needs.

  It does **not** make them independently verifiable. Recomputing one requires
  an ETF implementation, so in practice it requires the BEAM. `EventLedger`'s
  documentation used to claim independent verifiability; that claim is
  withdrawn rather than left standing, because a second implementation cannot
  reproduce these digests from a specification that fits on a page.

  Adopting a specified format — RFC 8785 JCS, or a length-prefixed encoding
  defined here — would earn the claim back. It would also change every existing
  identity, so it belongs to the recorded decision in
  `docs/decisions/2026-09-08-canonical-form.md` rather than to a quiet edit.
  """

  # Bumping this prefix is how a future encoding change stays distinguishable
  # from the current one. It is part of the hashed bytes.
  @version "sprucegoose-kernel-v1\0"

  # Pinned, not defaulted: an unpinned minor version makes the identity a
  # property of the runtime rather than of the value.
  @term_options [:deterministic, minor_version: 2]

  def encode(value) do
    with {:ok, normalized} <- normalize(value) do
      {:ok, @version <> :erlang.term_to_binary(normalized, @term_options)}
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
