defmodule SpruceGoose.AuthzLintTest do
  @moduledoc """
  The Workflows domain runs `authorize :when_requested`, so a bare `Ash.update/3`
  in the CLI is unauthorized *silently*. `SpruceGoose.Authz` is the funnel that
  makes that impossible — but only while every call actually goes through it.

  This test is what makes the funnel mandatory rather than merely available. It
  is deliberately a source-text check: the failure it guards against is a call
  that never runs in any other test, because it works fine — it just works
  without checking anything.
  """

  use ExUnit.Case, async: true

  @gated Path.wildcard("lib/spruce_goose/**/*.ex")
  @ash_gated ["lib/spruce_goose/cli/executor.ex", "lib/spruce_goose/revise.ex"]

  @raw_access ~r/\b(?:Repo\.(?:query!?|transaction|insert!?|update!?|delete!?|all|one)|Ecto\.Adapters\.SQL\.query!)\s*\(/

  # `Ash.Query.filter_input/2` builds a query without running it, and
  # `Ash.Notifier.notify/1` delivers notifications Ash already handed back —
  # neither reaches the data layer, so neither needs an actor.
  @forbidden ~w(Ash.create( Ash.update( Ash.destroy( Ash.read( Ash.read_one( Ash.get( Ash.count()

  test "no CLI module reaches Ash directly" do
    for path <- @ash_gated, call <- @forbidden do
      source = File.read!(path)

      refute String.contains?(source, call),
             """
             #{path} calls #{call}) directly.

             That call runs with no actor and no authorization, silently. Use the
             matching SpruceGoose.Authz function so the request's actor and
             `authorize?: true` are not optional.
             """
    end
  end

  test "the gated files exist, so a rename cannot silently empty this check" do
    for path <- @gated do
      assert File.exists?(path), "#{path} is gated by the authz lint but no longer exists"
    end
  end

  test "ledger authorization remains before filesystem and raw SQL access" do
    source = File.read!("lib/spruce_goose/ledger.ex")

    assert source =~
             ~r/def import\(path\) do\s+# Authorization[^\n]*\n\s+with \{:ok, actor\} <- authorize_admin\(\)/

    assert source =~
             ~r/def parity\(path\) do\s+# Authorization[^\n]*\n\s+with \{:ok, actor\} <- authorize_admin\(\)/

    assert source =~ "defp authorize_admin do"
    assert source =~ "Scope.holds?(actor, :admin, :global)"
  end

  test "every CLI-reachable raw data access has an adjacent authorization annotation" do
    for path <- @gated do
      assert_raw_access_is_annotated(File.read!(path), path)
    end

    assert_raise ExUnit.AssertionError, fn ->
      assert_raw_access_is_annotated("def unsafe, do: Repo.query!(\"SELECT 1\")", "mutation.ex")
    end
  end

  defp assert_raw_access_is_annotated(source, path) do
    lines = String.split(source, "\n")

    for {line, index} <- Enum.with_index(lines), Regex.match?(@raw_access, line) do
      context = lines |> Enum.slice(max(index - 3, 0), 4) |> Enum.join("\n")

      assert context =~ "AUTHORIZATION:",
             "#{path}:#{index + 1} has raw data access without an adjacent AUTHORIZATION annotation"
    end
  end
end
