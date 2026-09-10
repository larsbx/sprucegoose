defmodule SpruceGoose.Deployment.BuildManifestTest do
  use ExUnit.Case, async: true

  alias SpruceGoose.Deployment.BuildManifest

  @commit "0123456789abcdef0123456789abcdef01234567"
  @digest "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

  test "canonicalizes unordered declared inputs into one manifest digest" do
    assert {:ok, first} =
             BuildManifest.new(
               @commit,
               @digest,
               ["mix deps.get --only prod", "mix release"],
               %{"MIX_ENV" => "prod", "LANG" => "C.UTF-8"},
               [{"mix.lock", @digest}, {"mix.exs", @digest}]
             )

    assert {:ok, second} =
             BuildManifest.new(
               @commit,
               @digest,
               ["mix deps.get --only prod", "mix release"],
               %{"LANG" => "C.UTF-8", "MIX_ENV" => "prod"},
               [{"mix.exs", @digest}, {"mix.lock", @digest}]
             )

    assert first.encoded == second.encoded
    assert first.digest == second.digest
  end

  test "rejects ambient, ambiguous, and mutable build identities" do
    valid = [@commit, @digest, ["mix release"], %{}, [{"mix.exs", @digest}]]

    for invalid <- [
          ["main", @digest, ["mix release"], %{}, [{"mix.exs", @digest}]],
          [@commit, "builder:latest", ["mix release"], %{}, [{"mix.exs", @digest}]],
          [@commit, @digest, [], %{}, [{"mix.exs", @digest}]],
          [@commit, @digest, ["mix release"], %{MIX_ENV: "prod"}, [{"mix.exs", @digest}]],
          [@commit, @digest, ["mix release"], %{}, []],
          [@commit, @digest, ["mix release"], %{}, [{"../secret", @digest}]],
          [
            @commit,
            @digest,
            ["mix release"],
            %{},
            [{"mix.exs", @digest}, {"mix.exs", @digest}]
          ]
        ] do
      assert {:error, :invalid_build_manifest} = apply(BuildManifest, :new, invalid)
    end

    assert {:ok, _} = apply(BuildManifest, :new, valid)
  end
end
