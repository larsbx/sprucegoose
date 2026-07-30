defmodule SpruceGoose.Derive do
  @moduledoc """
  Deterministic identifier derivation (docs/identifier-model.md).

  Identity is *who authored which operation*, not *what the bytes were*. The
  body never enters a tuple here: `(peer_id, origin_seq)` is already unique per
  peer-operation, so including the body would add nothing to uniqueness while
  breaking idempotence — a corrected retry of the same logical event would mint
  a different ID. Payload integrity is a separate `payload_b3` concern.

  ## Classes

    * **O — originated.** Exactly one author.
      `d = H(NS, peer_id, u64be(origin_seq))`, `ts` stamped at origin.
    * **D — derived.** Deterministic function of an already-convergent parent.
      `d = H(NS, parent_id, discriminators...)`, `ts` inherited from the parent
      so children stay index-adjacent to it.
    * **I — upstream-imported.** Not implemented: no live source exposes a
      stable id plus `created_at`. See the doc for the exclusion rationale.
  """

  import Bitwise

  @typedoc "BLAKE3 digest, 32 bytes."
  @type digest :: <<_::256>>
  @max_u32 4_294_967_295
  @max_u48 281_474_976_710_655
  @max_u64 18_446_744_073_709_551_615

  # Namespaces keep the same dot from colliding across entity kinds.
  @ns_task "sg:task"
  @ns_todo "sg:todo"
  @ns_inbox "sg:inbox"
  @ns_board "sg:board"
  @ns_column "sg:column"
  @ns_filter "sg:filter"
  @ns_dependency "sg:dep"
  @ns_todo_dependency "sg:tododep"
  @ns_outbox "sg:outbox"

  def ns_task, do: @ns_task
  def ns_todo, do: @ns_todo
  def ns_inbox, do: @ns_inbox
  def ns_board, do: @ns_board
  def ns_column, do: @ns_column
  def ns_filter, do: @ns_filter
  def ns_dependency, do: @ns_dependency
  def ns_todo_dependency, do: @ns_todo_dependency
  def ns_outbox, do: @ns_outbox

  @doc """
  Length-prefixed field encoding.

  The prefix removes delimiter ambiguity: without it `enc("a:b")` and
  `enc("a") <> enc(":b")` would hash identically, so two different tuples could
  mint one ID.
  """
  @spec enc(binary()) :: binary()
  def enc(field) when is_binary(field), do: <<byte_size(field)::32>> <> field

  @doc "BLAKE3 over a namespace and length-prefixed fields."
  @spec h(binary(), [binary()]) :: digest()
  def h(namespace, fields) when is_binary(namespace) and is_list(fields) do
    B3.hash(Enum.reduce([namespace | fields], <<>>, fn f, acc -> acc <> enc(f) end))
  end

  @doc "Big-endian encodings, so a numeric field hashes identically everywhere."
  @spec u64be(non_neg_integer()) :: <<_::64>>
  def u64be(n) when is_integer(n) and n >= 0 and n <= @max_u64, do: <<n::64>>

  @spec u32be(non_neg_integer()) :: <<_::32>>
  def u32be(n) when is_integer(n) and n >= 0 and n <= @max_u32, do: <<n::32>>

  @doc """
  Deterministic, time-ordered, convergent UUIDv7 variant.

  The v7-versus-hash tension is false: it only exists if the digest occupies
  all 128 bits. Restricting it to the free bits preserves the sortable
  timestamp prefix.

      [  0.. 47]  ts_ms      convergent: origin's stamp, carried, never re-read
      [ 48.. 51]  0x7        version
      [ 52.. 63]  d[0..1]    12 digest bits
      [ 64.. 65]  0b10       variant
      [ 66..127]  d[2..9]    62 digest bits

  74 bits of digest. RFC 9562 leaves `rand_a`/`rand_b` implementation-defined,
  so a v7 whose tail is derived rather than random is conformant — but it will
  surprise a reader who assumes randomness, hence this note.

  `ts_ms` must be the originator's stamp, carried with the event. A receiving
  peer that re-reads its own clock derives a different ID for the same event.
  """
  @spec uuid_v7d(non_neg_integer(), digest()) :: binary()
  def uuid_v7d(ts_ms, digest)
      when is_integer(ts_ms) and ts_ms >= 0 and ts_ms <= @max_u48 and is_binary(digest) and
             byte_size(digest) >= 10 do
    <<rand_a::12, _skip::4, rand_b::62, _rest::bitstring>> = digest

    <<ts_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>
    |> format_uuid()
  end

  @doc "Class O: a freshly originated record."
  @spec originated(binary(), binary(), pos_integer(), non_neg_integer()) ::
          {binary(), digest()}
  def originated(namespace, peer_id, origin_seq, origin_wall_ms) do
    d = h(namespace, [peer_id, u64be(origin_seq)])
    {uuid_v7d(origin_wall_ms, d), d}
  end

  @doc """
  Class D: a record that is a deterministic function of a convergent parent.

  `ts` is inherited, never re-stamped, so children sort adjacent to their
  parent and two peers agree without coordinating clocks.
  """
  @spec derived(binary(), binary(), [binary()], non_neg_integer()) :: {binary(), digest()}
  def derived(namespace, parent_id, discriminators, parent_wall_ms) do
    d = h(namespace, [parent_id | discriminators])
    {uuid_v7d(parent_wall_ms, d), d}
  end

  @doc "Outbox event identity, projected from the Class D tuple."
  @spec outbox_event(binary(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {binary(), digest()}
  def outbox_event(task_id, revision, n, parent_wall_ms) do
    derived(@ns_outbox, task_id, [u64be(revision), u32be(n)], parent_wall_ms)
  end

  @doc """
  Task identifier suffix: the first 8 hex of `d`.

  Makes `tsk-<ts>-<hex8>` and the uuid two encodings of one identity rather
  than two independent identities.
  """
  @spec task_suffix(digest()) :: binary()
  def task_suffix(<<first::binary-size(4), _rest::binary>>),
    do: Base.encode16(first, case: :lower)

  defp format_uuid(<<a::32, b::16, c::16, d::16, e::48>>) do
    [
      pad(a, 8),
      pad(b, 4),
      pad(c, 4),
      pad(d, 4),
      pad(e, 12)
    ]
    |> Enum.join("-")
  end

  defp pad(value, width),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")

  @doc "Extract the millisecond timestamp back out of a derived uuid."
  @spec timestamp_ms(binary()) :: {:ok, non_neg_integer()} | :error
  def timestamp_ms(uuid) when is_binary(uuid) do
    with {:ok, raw} <- decode_uuid(uuid),
         <<ts::48, _rest::bitstring>> <- raw do
      {:ok, ts}
    else
      _ -> :error
    end
  end

  defp decode_uuid(uuid) do
    hex = String.replace(uuid, "-", "")

    case Base.decode16(hex, case: :mixed) do
      {:ok, raw} when byte_size(raw) == 16 -> {:ok, raw}
      _ -> :error
    end
  end

  @doc false
  def version_nibble(uuid) do
    with {:ok, <<_::48, v::4, _::bitstring>>} <- decode_uuid(uuid), do: v &&& 0xF
  end
end
