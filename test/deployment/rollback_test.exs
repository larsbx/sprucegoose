defmodule SpruceGoose.Deployment.RollbackTest do
  use ExUnit.Case, async: true
  alias SpruceGoose.Deployment.{Release, Rollback}

  defp deployment(id, commit) do
    {:ok, release} =
      Release.new(String.duplicate(commit, 40), "sha256:" <> String.duplicate(commit, 64))

    %{
      deployment_id: id,
      project: "sprucegoose",
      environment: "staging",
      state: :ready,
      release: release
    }
  end

  test "rollback requires distinct previously ready release in the same scope" do
    source = deployment("new", "a")
    target = deployment("old", "b")
    assert :ok = Rollback.validate(source, target)

    for invalid <- [
          nil,
          %{},
          %{target | deployment_id: source.deployment_id},
          %{target | project: "other"},
          %{target | environment: "production"},
          %{target | state: :staged},
          %{target | release: source.release},
          %{target | release: %{target.release | source_commit: "main"}}
        ] do
      assert {:error, :invalid_rollback_target} = Rollback.validate(source, invalid)
    end

    for state <- [:queued, :building, :staged, :rolling_back, :rolled_back, :cancelled] do
      assert {:error, :invalid_rollback_target} =
               Rollback.validate(%{source | state: state}, target)
    end
  end
end
