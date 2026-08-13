defmodule SpruceGoose.CIScaffoldTest do
  @moduledoc """
  Focused tests for provenance-independent CI and deployment scaffolding
  (tsk-20260813T141153Z-336632d6).

  These assertions are deliberately pure file/content checks. They must not
  require the SpruceGoose application, a database, or a booted runtime: the
  destination-migration lane is blocked, so a test that needed migrations
  would be an unauthorized execution rather than a test.

  Runnable standalone:

      ERL_CRASH_DUMP_SECONDS=0 elixir -e \
        'ExUnit.start(); Code.require_file("test/ci_scaffold_test.exs"); ExUnit.run()'
  """
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

  defp read(path), do: File.read!(Path.join(@root, path))
  defp exists?(path), do: File.exists?(Path.join(@root, path))

  describe "release configuration" do
    test "mix.exs declares an explicit releases block" do
      mix = read("mix.exs")

      assert mix =~ ~r/releases:\s*releases\(\)/,
             "project/0 must reference an explicit releases/0 block"

      assert mix =~ ~r/defp releases do/,
             "mix.exs must define releases/0 rather than relying on defaults"

      assert mix =~ ~r/spruce_goose:\s*\[/,
             "the release must be named spruce_goose"
    end

    test "release keeps compile provenance in the beams" do
      mix = read("mix.exs")

      refute mix =~ ~r/strip_beams:\s*true/,
             "stripping beams destroys the CInf chunk and with it compile provenance"

      assert mix =~ ~r/strip_beams:\s*false/,
             "strip_beams must be explicitly false so provenance survives the build"
    end

    test "mix.exs pins the elixir requirement" do
      assert read("mix.exs") =~ ~r/elixir:\s*"~>\s*1\.19"/
    end
  end

  describe "toolchain pin" do
    test ".tool-versions pins both erlang and elixir" do
      tools = read(".tool-versions")

      assert tools =~ ~r/^erlang 28\.3\.1$/m
      assert tools =~ ~r/^elixir 1\.19\.5-otp-28$/m
    end

    test "CI asserts the running toolchain matches the pin" do
      ci = read(".gitlab-ci.yml")

      assert ci =~ ".tool-versions",
             "CI must verify the toolchain against the declared pin, not assume it"
    end
  end

  describe "CI jobs" do
    setup do
      {:ok, ci: read(".gitlab-ci.yml")}
    end

    test "declares format, compile, and test jobs", %{ci: ci} do
      assert ci =~ ~r/^sprucegoose:format:/m
      assert ci =~ ~r/^sprucegoose:compile:/m
      assert ci =~ ~r/^sprucegoose:test:/m
    end

    test "compiles with warnings as errors", %{ci: ci} do
      assert ci =~ "--warnings-as-errors"
    end

    test "checks formatting without writing", %{ci: ci} do
      assert ci =~ "mix format --check-formatted"
    end

    test "suppresses crash dumps in every job", %{ci: ci} do
      assert ci =~ "ERL_CRASH_DUMP_SECONDS",
             "CI must not leave crash dumps in the workspace"
    end

    test "does not deploy, transfer, or contact the authority host", %{ci: ci} do
      refute ci =~ ~r/\bssh\b/
      refute ci =~ ~r/\bscp\b|\brsync\b/
      refute ci =~ ~r/\bmama\b/i
      refute ci =~ ~r/systemctl/
    end
  end

  describe "inert deploy and rollback scripts" do
    for script <- ["scripts/deploy-sprucegoose", "scripts/rollback-sprucegoose"] do
      test "#{script} exists and is executable" do
        path = Path.join(@root, unquote(script))
        assert File.exists?(path)
        assert %{mode: mode} = File.stat!(path)
        assert Bitwise.band(mode, 0o111) != 0, "#{unquote(script)} must be executable"
      end

      test "#{script} is inert and refuses to run" do
        body = read(unquote(script))

        assert body =~ "INERT",
               "the script must declare itself inert"

        assert body =~ ~r/exit\s+[1-9]/,
               "the script must exit non-zero rather than acting"
      end

      test "#{script} performs no privileged or remote action" do
        body = read(unquote(script))

        for forbidden <- ["systemctl", "psql", "mix ecto.migrate", "scp ", "rsync "] do
          refute String.contains?(body, forbidden),
                 "#{unquote(script)} must not contain #{forbidden} while inert"
        end
      end
    end
  end

  describe "scoped read-only database role declaration" do
    test "the declaration exists and is marked unapplied" do
      assert exists?("priv/repo/roles/sprucegoose_readonly.sql")
      sql = read("priv/repo/roles/sprucegoose_readonly.sql")

      assert sql =~ "NOT APPLIED",
             "the declaration must state that it has not been applied"
    end

    test "the role grants only read access" do
      sql = read("priv/repo/roles/sprucegoose_readonly.sql") |> String.upcase()

      assert sql =~ "GRANT SELECT"
      # The real PostgreSQL setting is default_transaction_read_only, all
      # underscores. An earlier revision of this assertion spelled it with a
      # space, which no server would ever accept.
      assert sql =~ "DEFAULT_TRANSACTION_READ_ONLY"

      for forbidden <- ["GRANT INSERT", "GRANT UPDATE", "GRANT DELETE", "GRANT ALL", "SUPERUSER"] do
        refute sql =~ forbidden, "read-only role must not include #{forbidden}"
      end
    end

    test "the declaration is not wired into any migration" do
      migrations = Path.wildcard(Path.join(@root, "priv/repo/migrations/*.exs"))

      for file <- migrations do
        refute File.read!(file) =~ "sprucegoose_readonly",
               "the role declaration must stay unapplied: #{Path.basename(file)}"
      end
    end
  end

  describe "lane exclusions" do
    test "provenance-lane paths are absent from this worktree" do
      for path <- [
            "scripts/build-governed-release",
            "scripts/validate-governed-release",
            "docs/release-provenance.md",
            "lib/spruce_goose/release_provenance.ex",
            "lib/spruce_goose/release_validator.ex"
          ] do
        refute exists?(path),
               "#{path} belongs to tsk-20260813T111813Z-19e119cb and must not appear here"
      end
    end
  end
end
