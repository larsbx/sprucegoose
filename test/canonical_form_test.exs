defmodule SpruceGoose.CanonicalFormTest do
  @moduledoc """
  RFC 8785 conformance for the value types the ledger carries, and the
  guarantee that the legacy form still re-derives.
  """
  use ExUnit.Case, async: true

  alias SpruceGoose.Kernel.{Canonical, CertifiedEvent, ContentID}

  test "JCS: keys sort by UTF-16 code units, strings escape like JSON.stringify, no whitespace" do
    # Key order from RFC 8785 §3.2.3: "€" (euro) sorts before "😀" (U+1F600,
    # surrogate pair) because code units, not code points, decide.
    value = %{"€" => 1, "😀" => 2, "a" => 3, "A" => 4, "" => 5}
    assert {:ok, ~s({"":5,"A":4,"a":3,"€":1,"😀":2})} = Canonical.encode(value)

    assert {:ok, ~s("\\"\\\\\\b\\f\\n\\r\\t\\u001f é")} =
             Canonical.encode(~s("\\) <> <<8, 12, 10, 13, 9, 0x1F>> <> " é")

    assert {:ok, ~s([null,true,false,0,-1,9007199254740991,[],{}])} =
             Canonical.encode([nil, true, false, 0, -1, 9_007_199_254_740_991, [], %{}])
  end

  test "JCS refuses what it cannot canonicalise rather than inventing a convention" do
    assert {:error, :noncanonical_value} = Canonical.encode(1.5)
    assert {:error, :noncanonical_value} = Canonical.encode(%{atom: 1})
    assert {:error, :noncanonical_value} = Canonical.encode(9_007_199_254_740_992)
    assert {:error, :noncanonical_value} = Canonical.encode(%{"x" => :atom})
  end

  test "the same content has a different identity in each form, and both re-derive" do
    attrs = %{
      stream: "s",
      event_type: "T",
      idempotency_key: "k",
      payload: %{"n" => 1},
      roots: %{"schema" => "sha256:abc"}
    }

    {:ok, jcs} = CertifiedEvent.new(attrs)
    {:ok, etf} = CertifiedEvent.new(attrs, :etf)

    assert jcs.canonical_form == :jcs
    assert etf.canonical_form == :etf
    refute jcs.identity == etf.identity

    assert jcs.canonical_bytes ==
             ~s({"event_type":"T","idempotency_key":"k","payload":{"n":1},"roots":{"schema":"sha256:abc"},"stream":"s"})

    assert jcs.identity.digest ==
             :crypto.hash(:sha256, jcs.canonical_bytes) |> Base.encode16(case: :lower)

    assert :ok = ContentID.verify(etf.identity, etf.canonical_bytes)
    assert "sprucegoose-kernel-v1\0" <> _ = etf.canonical_bytes
  end
end
