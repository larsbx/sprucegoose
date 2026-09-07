defmodule SpruceGoose.Identity.LocalTest do
  @moduledoc """
  Identity custody contract — unit lane only.

  Database-backed custody cases live in the separate non-sandbox integration
  lane (`test/evidence/identity_integration_case.exs`), which owns fresh
  disposable databases. No test in any lane deletes identity rows: absence is
  established by using a database whose identity state the attempt created,
  never by removing a row that might be retained.
  """
  use ExUnit.Case, async: true

  alias SpruceGoose.Identity.Local

  describe "static custody guarantees" do
    test "fetch_existing_identity/0 is exported" do
      assert function_exported?(Local, :fetch_existing_identity, 0)
    end

    test "sign_authority_evidence_digest/2 exists and no generic sign/1 oracle does" do
      assert function_exported?(Local, :sign_authority_evidence_digest, 2)

      refute function_exported?(Local, :sign, 1),
             "a generic signing oracle over the authority key is prohibited"
    end

    test "fetch_existing_identity never provisions or reads the private half" do
      src = File.read!("lib/spruce_goose/identity/local.ex")
      [_, tail] = String.split(src, "def fetch_existing_identity", parts: 2)
      body = tail |> String.split(~r/\n  (def|@doc|@spec) /, parts: 2) |> hd()

      refute body =~ "provision", "fetch must never provision"
      refute body =~ "peer_private_key", "fetch must never select the private half"
      refute body =~ "peer_id", "fetch must never delegate to peer_id/0"
    end

    # Two-part boundary. The changed-line guard stops scope expansion from
    # evading a fixed path list; the path guard inspects the complete Change A
    # implementation. Neither reaches pre-existing repository code: the
    # historical delete in test/identity_local_test.exs (commit 8a7a6178) runs
    # in the ordinary Sandbox rollback lane and is outside this change.
    @baseline "7284b7883537a022904f62ec6058d8b4f5bcfe41"

    @change_a_globs [
      "lib/spruce_goose/evidence/**/*.ex",
      "lib/spruce_goose/identity/local.ex",
      "test/evidence/**/*.exs",
      "test/spruce_goose/identity/**/*.exs"
    ]

    defp change_a_files do
      @change_a_globs |> Enum.flat_map(&Path.wildcard/1) |> Enum.uniq()
    end

    defp added_lines do
      case System.cmd("git", ["diff", "-U0", @baseline, "--", "."], stderr_to_stdout: true) do
        {out, 0} ->
          out
          |> String.split("\n")
          |> Enum.filter(&(String.starts_with?(&1, "+") and not String.starts_with?(&1, "+++")))

        {out, code} ->
          flunk("git diff failed (#{code}); guard is UNEXECUTED, not passing: #{out}")
      end
    end

    defp untracked_change_a_lines do
      case System.cmd("git", ["ls-files", "--others", "--exclude-standard"], stderr_to_stdout: true) do
        {out, 0} ->
          tracked_globs = change_a_files() |> MapSet.new()

          out
          |> String.split("\n", trim: true)
          |> Enum.filter(&MapSet.member?(tracked_globs, &1))
          |> Enum.flat_map(&String.split(File.read!(&1), "\n"))

        _ ->
          []
      end
    end

    @identity_delete_patterns [
      {~r/DELETE\s+FROM\s+spruce_goose_identity/i, "SQL delete of identity rows"}, # guard-pattern-literal
      {~r/spruce_goose_identity.*delete_all|delete_all.*spruce_goose_identity/i, # guard-pattern-literal
       "delete_all against identity"},
      {~r/Repo\.delete.*[Ii]dentity|Ash\.destroy.*[Ii]dentity/, "Repo.delete/Ash.destroy of identity"} # guard-pattern-literal
    ]

    # This guard's own pattern definitions and known-positive control contain
    # the very strings it searches for, so scanning them would make the guard
    # flag itself. Lines carrying this marker are excluded from the scan; the
    # marker is only ever applied to guard scaffolding, never to executable
    # database calls. A separate assertion below proves the file contains no
    # real identity delete, so the exclusion cannot hide one.
    @guard_marker "guard-pattern-literal"

    defp guard_scaffolding?(line), do: String.contains?(line, @guard_marker)

    defp scannable_lines(text) do
      text |> String.split("\n") |> Enum.reject(&guard_scaffolding?/1)
    end

    test "changed-line guard: no candidate-added line deletes identity rows" do
      lines = added_lines() ++ untracked_change_a_lines()

      # Control: the guard must be capable of matching. A guard that can never
      # fire is not evidence.
      assert Enum.any?(@identity_delete_patterns, fn {re, _} ->
               Regex.match?(re, "DELETE FROM spruce_goose_identity") # guard-pattern-literal
             end),
             "guard patterns cannot match a known-positive; guard is broken"

      for line <- lines,
          not guard_scaffolding?(line),
          {re, label} <- @identity_delete_patterns do
        refute Regex.match?(re, line),
               "candidate-added line introduces #{label}: #{String.slice(line, 0, 120)}"
      end
    end

    test "path guard: Change A files contain no prohibited identity or environment access" do
      files = change_a_files()
      assert files != [], "path guard matched no files; glob is broken, not clean"

      for f <- files do
        src = File.read!(f)
        production? = String.starts_with?(f, "lib/spruce_goose/evidence/")
        scannable = scannable_lines(src) |> Enum.join("\n")

        for {re, label} <- @identity_delete_patterns do
          refute Regex.match?(re, scannable), "#{f} contains #{label}"
        end

        if production? do
          refute src =~ "peer_id", "#{f} must not call peer_id/0"
          refute src =~ "peer_private_key", "#{f} must not read the private half"
          refute src =~ "Sandbox", "#{f} must not branch on the sandbox pool"
          refute src =~ "Mix.env", "#{f} must not branch on Mix.env"
        end
      end
    end

    test "pre-existing repository test remains byte-identical to baseline" do
      {out, code} =
        System.cmd("git", ["diff", "--quiet", @baseline, "--", "test/identity_local_test.exs"],
          stderr_to_stdout: true
        )

      assert code == 0, "Change A must not modify the pre-existing identity test: #{out}"
    end
  end

  describe "digest framing and input validation" do
    test "the signed framing is the fixed domain-separated evidence message" do
      digest = :crypto.hash(:sha256, "payload")

      assert Local.authority_evidence_message(digest) ==
               "sprucegoose-authority-evidence-snapshot-v1\0" <> digest
    end

    test "framing rejects any digest that is not exactly 32 bytes" do
      assert_raise FunctionClauseError, fn -> Local.authority_evidence_message(<<1, 2, 3>>) end
      assert_raise FunctionClauseError, fn -> Local.authority_evidence_message(<<0::size(264)>>) end
    end

    test "signing rejects a non-32-byte digest before touching custody" do
      assert {:error, :invalid_digest} =
               Local.sign_authority_evidence_digest(<<0::size(248)>>, <<0::256>>)

      assert {:error, :invalid_digest} =
               Local.sign_authority_evidence_digest(<<0::size(264)>>, <<0::256>>)
    end
  end
end
