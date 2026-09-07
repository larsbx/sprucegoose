defmodule SpruceGoose.Evidence.BoundsTest do
  use ExUnit.Case, async: true

  alias SpruceGoose.Evidence.Bounds

  test "declared maxima are exposed and positive" do
    d = Bounds.declared()
    for k <- [:projects, :revisions, :workflows, :definitions, :tasks, :pages,
              :page_size, :serialized_bytes, :transaction_ms] do
      assert is_integer(d[k]) and d[k] > 0, "missing or invalid bound: #{k}"
    end
  end

  test "within-bound count passes" do
    assert :ok = Bounds.check(:tasks, 10)
  end

  test "exceeding a bound returns a typed refusal, never a truncation" do
    over = Bounds.declared()[:tasks] + 1
    assert {:error, {:bound_exceeded, :tasks, ^over, _limit}} = Bounds.check(:tasks, over)
  end

  test "serialized bytes are enforced incrementally, not after assembly" do
    limit = Bounds.declared()[:serialized_bytes]
    acc = Bounds.new_accumulator()
    assert {:ok, acc} = Bounds.add_bytes(acc, :binary.copy("x", 100))
    assert {:error, {:bound_exceeded, :serialized_bytes, _, ^limit}} =
             Bounds.add_bytes(acc, :binary.copy("x", limit + 1))
  end

  test "deadline refusal is typed and distinguishable from success" do
    past = System.monotonic_time(:millisecond) - 1
    assert {:error, {:deadline_exceeded, :transaction_ms, _}} = Bounds.check_deadline(past)
    future = System.monotonic_time(:millisecond) + 60_000
    assert :ok = Bounds.check_deadline(future)
  end
end
