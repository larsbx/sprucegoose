defmodule SpruceGoose.KnowledgeGenerationTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Knowledge.Generation

  defp generation(suffix) do
    Ash.create!(Generation, %{
      source: "test",
      source_revision: "rev-#{suffix}",
      source_digest: String.duplicate(suffix, 64)
    })
  end

  test "a generation is born active and the caller cannot choose otherwise" do
    assert generation("a").state == :active

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.create(Generation, %{
               source: "test",
               source_revision: "rev-b",
               source_digest: String.duplicate("b", 64),
               state: :retired
             })
  end

  test "retire is a single edge: active → retired, never twice" do
    retired = generation("c") |> Ash.update!(%{}, action: :retire)
    assert retired.state == :retired

    assert {:error, error} = Ash.update(retired, %{}, action: :retire)
    assert Exception.message(error) =~ "already retired"
  end
end
