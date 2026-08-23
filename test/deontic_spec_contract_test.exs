defmodule SpruceGoose.DeonticSpecContractTest do
  use ExUnit.Case, async: true

  @contract Path.expand("../docs/deontic-spec-contract.md", __DIR__)

  test "the deontic contract remains non-operative and covers kernel invariants" do
    contract = File.read!(@contract)

    assert contract =~ "Status: **DRAFT — NON-OPERATIVE**"

    assert contract =~
             "ontology, schema, norm, policy, grant epoch, agent charter, interpreter, and evidence-policy"

    assert contract =~ "EffectIntent.executed?` is false"
    assert contract =~ "G1 — No self-adoption"
    assert contract =~ "no `SpecAdopted` primitive or verifier exists"
    assert contract =~ "There is no permissive fallback."
  end
end
