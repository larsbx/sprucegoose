defmodule SpruceGoose.Evidence.CanonicalJsonTest do
  use ExUnit.Case, async: true

  alias SpruceGoose.Evidence.CanonicalJson, as: CJ

  describe "determinism" do
    test "map insertion order does not change bytes" do
      a = %{"alpha" => 1, "beta" => 2, "gamma" => 3}
      b = %{"gamma" => 3, "beta" => 2, "alpha" => 1}
      assert {:ok, bytes_a} = CJ.encode(a)
      assert {:ok, bytes_b} = CJ.encode(b)
      assert bytes_a == bytes_b
    end

    test "nested maps are sorted recursively" do
      a = %{"outer" => %{"z" => 1, "a" => 2}}
      b = %{"outer" => %{"a" => 2, "z" => 1}}
      assert {:ok, x} = CJ.encode(a)
      assert {:ok, y} = CJ.encode(b)
      assert x == y
      assert x == ~s({"outer":{"a":2,"z":1}})
    end

    test "keys sort by UTF-8 byte order, not codepoint collation" do
      assert {:ok, bytes} = CJ.encode(%{"Z" => 1, "a" => 2, "A" => 3})
      assert bytes == ~s({"A":3,"Z":1,"a":2})
    end

    test "arrays preserve declared order" do
      assert {:ok, bytes} = CJ.encode(%{"k" => [3, 1, 2]})
      assert bytes == ~s({"k":[3,1,2]})
    end

    test "emits no whitespace" do
      assert {:ok, bytes} = CJ.encode(%{"a" => 1, "b" => [1, 2]})
      refute bytes =~ ~r/\s/
    end
  end

  describe "fixed positive vectors" do
    test "integers use minimal decimal form" do
      assert {:ok, ~s({"n":0})} = CJ.encode(%{"n" => 0})
      assert {:ok, ~s({"n":-1})} = CJ.encode(%{"n" => -1})
      assert {:ok, ~s({"n":10})} = CJ.encode(%{"n" => 10})
    end

    test "booleans and null" do
      assert {:ok, ~s({"f":false,"n":null,"t":true})} =
               CJ.encode(%{"t" => true, "f" => false, "n" => nil})
    end

    test "escaping and unicode are preserved" do
      assert {:ok, bytes} = CJ.encode(%{"k" => "a\"b\\c"})
      assert bytes == ~s({"k":"a\\"b\\\\c"})
      assert {:ok, u} = CJ.encode(%{"k" => "héllo→"})
      assert u == ~s({"k":"héllo→"})
    end
  end

  describe "adversarial rejection" do
    test "floats rejected" do
      assert {:error, :float_not_permitted} = CJ.encode(%{"n" => 1.5})
    end

    test "atom values rejected at the encoding boundary" do
      assert {:error, :atom_not_permitted} = CJ.encode(%{"k" => :some_atom})
    end

    test "atom keys rejected" do
      assert {:error, :non_string_key} = CJ.encode(%{atom_key: 1})
    end

    test "invalid UTF-8 rejected" do
      assert {:error, :invalid_utf8} = CJ.encode(%{"k" => <<0xFF, 0xFE>>})
    end

    test "duplicate logical keys rejected before encoding" do
      assert {:error, :duplicate_key} = CJ.encode([{"a", 1}, {"a", 2}])
    end
  end
end
