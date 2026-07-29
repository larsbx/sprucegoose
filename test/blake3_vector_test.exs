defmodule SpruceGoose.Blake3VectorTest do
  @moduledoc """
  Known-answer tests for the BLAKE3 implementation backing identifier
  derivation (docs/identifier-model.md).

  The identifier model makes IDs a pure function of a hash. If the hash is
  wrong, every derived ID is wrong and two peers silently disagree. Pinning
  official vectors means a dependency swap cannot change digests unnoticed.

  Vectors from the BLAKE3 reference implementation.
  """
  use ExUnit.Case, async: true

  @vectors [
    {"", "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"},
    {"a", "17762fddd969a453925d65717ac3eea21320b66b54342fde15128d6caf21215f"},
    {"abc", "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"},
    {"hello world", "d74981efa70a0c880b8d8c1985d075dbcbf679b99a5f9914e5aaf96b831a9e24"}
  ]

  test "BLAKE3 matches the reference vectors" do
    for {input, expected} <- @vectors do
      assert B3.hash(input) |> Base.encode16(case: :lower) == expected,
             "BLAKE3 digest mismatch for #{inspect(input)}"
    end
  end

  test "digest is 32 bytes and stable across calls" do
    assert byte_size(B3.hash("spruce")) == 32
    assert B3.hash("spruce") == B3.hash("spruce")
  end
end
