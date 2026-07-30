defmodule SpruceGoose.DeriveGoldenTest do
  @moduledoc """
  Golden vectors for identifier derivation (docs/identifier-model.md).

  These values are the contract. Derived IDs are a pure function of
  `enc/1`, `h/2`, and `uuid_v7d/2`, so any change to those functions changes
  every ID this system will ever mint — and, worse, makes two peers running
  different versions disagree *silently* rather than erroring.

  If a change here is deliberate, it is a breaking change to identity and
  needs a migration plan, not a test update.

  The peer key is a fixed non-secret pattern so vectors are reproducible.
  """
  use ExUnit.Case, async: true

  alias SpruceGoose.Derive

  # 32 bytes of 0xAB. Not a real key; fixed so vectors are stable.
  @peer :binary.copy(<<0xAB>>, 32)
  @ts 1_753_800_000_000

  describe "enc/1 length prefixing" do
    test "prefixes with a big-endian u32 byte count" do
      assert Base.encode16(Derive.enc("abc"), case: :lower) == "00000003616263"
      assert Base.encode16(Derive.enc(""), case: :lower) == "00000000"
    end

    test "removes delimiter ambiguity" do
      # Without the prefix these would hash identically and two distinct
      # tuples could mint one ID.
      refute Derive.enc("a:b") == Derive.enc("a") <> Derive.enc(":b")
    end
  end

  describe "fixed-width integer boundaries" do
    test "accepts exact maxima" do
      assert Derive.u32be(4_294_967_295) == <<255, 255, 255, 255>>
      assert Derive.u64be(18_446_744_073_709_551_615) == :binary.copy(<<255>>, 8)
    end

    test "rejects overflow instead of wrapping" do
      assert_raise FunctionClauseError, fn -> Derive.u32be(4_294_967_296) end
      assert_raise FunctionClauseError, fn -> Derive.u64be(18_446_744_073_709_551_616) end
    end
  end

  describe "h/2 BLAKE3 over namespace and fields" do
    test "task class O digest" do
      assert Derive.h(Derive.ns_task(), [@peer, Derive.u64be(1)])
             |> Base.encode16(case: :lower) ==
               "423193bc2f1b2106520fe71bb89eff7deaee5a9fb6ede10c69aeb92ee98a56f5"
    end

    test "outbox class D digest" do
      assert Derive.h(Derive.ns_outbox(), [
               "tsk-20260729T000000Z-deadbeef",
               Derive.u64be(3),
               Derive.u32be(2)
             ])
             |> Base.encode16(case: :lower) ==
               "ba9909b29f2e8cc1cbca2fe53880917bc57c84759ea83e83304d3c8a91578235"
    end

    test "namespace separates otherwise identical tuples" do
      refute Derive.h(Derive.ns_task(), [@peer, Derive.u64be(1)]) ==
               Derive.h(Derive.ns_todo(), [@peer, Derive.u64be(1)])
    end
  end

  describe "uuid_v7d/2 bit layout" do
    setup do
      %{d: Derive.h(Derive.ns_task(), [@peer, Derive.u64be(1)])}
    end

    test "class O and class D golden uuids", %{d: _d} do
      {uuid_o, _} = Derive.originated(Derive.ns_task(), @peer, 1, @ts)
      assert uuid_o == "019856a0-4200-7423-a4ef-0bc6c8419483"

      {uuid_d, _} = Derive.outbox_event("tsk-20260729T000000Z-deadbeef", 3, 2, @ts)
      assert uuid_d == "019856a0-4200-7ba9-826c-a7cba33072f2"
    end

    test "version nibble is 7", %{d: d} do
      assert Derive.version_nibble(Derive.uuid_v7d(@ts, d)) == 7
    end

    test "variant bits are 0b10", %{d: d} do
      {:ok, raw} =
        Derive.uuid_v7d(@ts, d) |> String.replace("-", "") |> Base.decode16(case: :lower)

      <<_::64, variant::2, _::bitstring>> = raw
      assert variant == 2
    end

    test "timestamp occupies the leading 48 bits and round-trips", %{d: d} do
      assert Derive.timestamp_ms(Derive.uuid_v7d(@ts, d)) == {:ok, @ts}
      assert Derive.uuid_v7d(0, d) == "00000000-0000-7423-a4ef-0bc6c8419483"

      assert Derive.uuid_v7d(281_474_976_710_655, d) ==
               "ffffffff-ffff-7423-a4ef-0bc6c8419483"
    end

    test "rejects timestamp overflow instead of wrapping", %{d: d} do
      assert_raise FunctionClauseError, fn -> Derive.uuid_v7d(281_474_976_710_656, d) end
    end

    test "is deterministic for a fixed (ts, d)", %{d: d} do
      assert Derive.uuid_v7d(@ts, d) == Derive.uuid_v7d(@ts, d)
    end

    test "sorts by time, so index locality survives derivation", %{d: d} do
      earlier = Derive.uuid_v7d(@ts, d)
      later = Derive.uuid_v7d(@ts + 1000, d)
      assert earlier < later
    end

    test "digest changes the tail while the timestamp prefix is preserved", %{d: d} do
      other = Derive.h(Derive.ns_task(), [@peer, Derive.u64be(2)])

      a = Derive.uuid_v7d(@ts, d)
      b = Derive.uuid_v7d(@ts, other)

      refute a == b
      assert Derive.timestamp_ms(a) == Derive.timestamp_ms(b)
    end
  end

  describe "peer convergence" do
    test "same dot converges; distinct dots diverge" do
      {a, _} = Derive.originated(Derive.ns_task(), @peer, 1, @ts)
      {a_again, _} = Derive.originated(Derive.ns_task(), @peer, 1, @ts)

      # Same logical operation replayed by the same peer: one identity.
      assert a == a_again

      other_peer = :binary.copy(<<0xCD>>, 32)
      {b, _} = Derive.originated(Derive.ns_task(), other_peer, 1, @ts)
      refute a == b

      {next_seq, _} = Derive.originated(Derive.ns_task(), @peer, 2, @ts)
      refute a == next_seq
    end

    test "the body is not an input, so a corrected retry keeps its identity" do
      # Identity is who authored which operation. Two calls with the same dot
      # agree regardless of any payload, which is what makes a corrected retry
      # idempotent instead of minting a duplicate.
      {first, _} = Derive.originated(Derive.ns_inbox(), @peer, 7, @ts)
      {retry, _} = Derive.originated(Derive.ns_inbox(), @peer, 7, @ts)
      assert first == retry
    end
  end

  describe "class D inheritance" do
    test "children inherit the parent timestamp and stay index-adjacent" do
      parent_ts = @ts
      {one, _} = Derive.outbox_event("tsk-20260729T000000Z-deadbeef", 1, 0, parent_ts)
      {two, _} = Derive.outbox_event("tsk-20260729T000000Z-deadbeef", 1, 1, parent_ts)

      assert Derive.timestamp_ms(one) == {:ok, parent_ts}
      assert Derive.timestamp_ms(two) == {:ok, parent_ts}
      refute one == two
    end

    test "revision and index are discriminators" do
      base = "tsk-20260729T000000Z-deadbeef"
      {r1, _} = Derive.outbox_event(base, 1, 0, @ts)
      {r2, _} = Derive.outbox_event(base, 2, 0, @ts)
      {n1, _} = Derive.outbox_event(base, 1, 1, @ts)

      assert Enum.uniq([r1, r2, n1]) == [r1, r2, n1]
    end
  end

  describe "task suffix" do
    test "is the first 8 hex of the digest, tying tsk- id to the uuid" do
      d = Derive.h(Derive.ns_task(), [@peer, Derive.u64be(1)])
      assert Derive.task_suffix(d) == "423193bc"

      # The same digest bits appear in the uuid, so the two encodings are one
      # identity rather than two.
      {uuid, _} = Derive.originated(Derive.ns_task(), @peer, 1, @ts)
      assert String.contains?(uuid, "423")
    end
  end
end
