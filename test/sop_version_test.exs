defmodule SpruceGoose.SopVersionTest do
  @moduledoc """
  The SOP version rule, one test per row of the table in `SpruceGoose.SopGate`.

  This is the only control on the fleet that was deliberately *loosened*, so
  every branch is pinned — including the ones that must still refuse. The
  refusals are the point: a patch bump is allowed to skip re-acknowledgment
  precisely because everything else still cannot.
  """

  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.SopGate

  setup do
    dir = Path.join(System.tmp_dir!(), "sop-version-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "Systemwide SOP.md")

    original = Application.fetch_env!(:spruce_goose, :systemwide_sop_path)
    Application.put_env(:spruce_goose, :systemwide_sop_path, path)

    on_exit(fn ->
      Application.put_env(:spruce_goose, :systemwide_sop_path, original)
      File.rm_rf(dir)
    end)

    {:ok, path: path}
  end

  describe "an unversioned SOP behaves exactly as before" do
    test "matching digest verifies", %{path: path} do
      write(path, nil, "# Systemwide SOP\n")
      {:ok, ack} = SopGate.acknowledge(path)

      assert ack.sop_version == nil
      assert SopGate.verify(gate(ack)) == :ok
    end

    test "any byte change refuses", %{path: path} do
      write(path, nil, "# Systemwide SOP\n")
      {:ok, ack} = SopGate.acknowledge(path)

      write(path, nil, "# Systemwide SOP\n\nOne more line.\n")

      assert {:error, message} = SopGate.verify(gate(ack))
      assert message =~ "stale"
    end
  end

  describe "a versioned SOP" do
    test "a patch bump does not invalidate the acknowledgment", %{path: path} do
      write(path, "2.1.0", "# Systemwide SOP\n\nA sentence with a typo.\n")
      {:ok, ack} = SopGate.acknowledge(path)
      assert ack.sop_version == "2.1.0"

      write(path, "2.1.1", "# Systemwide SOP\n\nA sentence without a typo.\n")

      assert SopGate.verify(gate(ack)) == :ok
      # The digest still records the bytes actually read, unchanged until the
      # task next acknowledges. That is the evidence a patch bump was honest.
      assert gate(ack).sop_digest ==
               sha256("2.1.0", "# Systemwide SOP\n\nA sentence with a typo.\n")
    end

    test "a minor bump refuses, naming both versions", %{path: path} do
      write(path, "2.1.0", "# Systemwide SOP\n")
      {:ok, ack} = SopGate.acknowledge(path)

      write(path, "2.2.0", "# Systemwide SOP\n\nA new rule.\n")

      assert {:error, message} = SopGate.verify(gate(ack))
      assert message =~ "acknowledged 2.1.0"
      assert message =~ "now 2.2.0"
    end

    test "a major bump refuses", %{path: path} do
      write(path, "2.1.0", "# Systemwide SOP\n")
      {:ok, ack} = SopGate.acknowledge(path)

      write(path, "3.0.0", "# Systemwide SOP\n\nEverything changed.\n")

      assert {:error, _message} = SopGate.verify(gate(ack))
    end

    test "a rollback to a lower version refuses rather than re-validating", %{path: path} do
      write(path, "2.4.0", "# Systemwide SOP\n")
      {:ok, ack} = SopGate.acknowledge(path)

      # Same MAJOR.MINOR would pass the equality test, so the rollback check has
      # to come first or reverting the SOP would silently revalidate.
      write(path, "2.3.0", "# Systemwide SOP\n")

      assert {:error, message} = SopGate.verify(gate(ack))
      assert message =~ "older than"
      assert message =~ "does not re-validate"
    end
  end

  describe "grandfathering" do
    test "a version-less acknowledgment survives the SOP declaring its baseline", %{path: path} do
      # The migration case: acknowledge before versioning exists, then the SOP
      # gains frontmatter. If this refused, introducing versioning would be the
      # exact flag day versioning exists to prevent.
      write(path, nil, "# Systemwide SOP\n")
      {:ok, ack} = SopGate.acknowledge(path)
      assert ack.sop_version == nil

      write(path, SopGate.grandfather_version(), "# Systemwide SOP\n")

      assert SopGate.verify(gate(ack)) == :ok
    end

    test "and a patch on top of the baseline still survives", %{path: path} do
      write(path, nil, "# Systemwide SOP\n")
      {:ok, ack} = SopGate.acknowledge(path)

      write(path, "1.0.4", "# Systemwide SOP\n\nTypo fixed.\n")

      assert SopGate.verify(gate(ack)) == :ok
    end

    test "but a semantic bump refuses, saying what it was treated as", %{path: path} do
      write(path, nil, "# Systemwide SOP\n")
      {:ok, ack} = SopGate.acknowledge(path)

      write(path, "1.1.0", "# Systemwide SOP\n\nA new rule.\n")

      assert {:error, message} = SopGate.verify(gate(ack))
      assert message =~ "predates SOP versioning"
      assert message =~ SopGate.grandfather_version()
    end
  end

  describe "fail-closed edges" do
    test "removing the version while a task holds one refuses", %{path: path} do
      write(path, "2.1.0", "# Systemwide SOP\n")
      {:ok, ack} = SopGate.acknowledge(path)

      write(path, nil, "# Systemwide SOP\n")

      assert {:error, message} = SopGate.verify(gate(ack))
      assert message =~ "no longer declares a version"
    end

    test "an unclosed frontmatter block refuses rather than being ignored", %{path: path} do
      File.write!(path, "---\nversion: 2.1.0\n\n# Systemwide SOP\n")

      assert {:error, message} = SopGate.acknowledge(path)
      assert message =~ "never closes"
    end

    test "a non-semver version refuses", %{path: path} do
      write(path, "v2", "# Systemwide SOP\n")

      assert {:error, message} = SopGate.acknowledge(path)
      assert message =~ "not semantic versioning"
    end

    test "an unsupported frontmatter key refuses", %{path: path} do
      File.write!(path, "---\nversion: 2.1.0\nowner: someone\n---\n\n# Systemwide SOP\n")

      assert {:error, message} = SopGate.acknowledge(path)
      assert message =~ "unsupported key"
    end

    test "frontmatter with no version at all refuses", %{path: path} do
      File.write!(path, "---\nsop_id: systemwide-sop\n---\n\n# Systemwide SOP\n")

      assert {:error, message} = SopGate.acknowledge(path)
      assert message =~ "declares no version"
    end

    test "a sop_id naming another document refuses", %{path: path} do
      File.write!(path, "---\nsop_id: some-other-sop\nversion: 2.1.0\n---\n\n# Systemwide SOP\n")

      assert {:error, message} = SopGate.acknowledge(path)
      assert message =~ "expected \"systemwide-sop\""
    end

    test "an ungated task is still exempt", %{path: path} do
      write(path, "2.1.0", "# Systemwide SOP\n")
      assert SopGate.verify(%{sop_gate_required: false}) == :ok
    end
  end

  # -- helpers ----------------------------------------------------------------

  describe "adoption" do
    test "the adopted digest is readable from the repository alone", %{} do
      assert {:ok, "sha256:" <> hex} = SopGate.adopted_digest()
      assert String.match?(hex, ~r/\A[0-9a-f]{64}\z/)
    end

    test "a deployed SOP that diverges from the adopted digest is refused", %{path: path} do
      write(path, "1.0.0", "Deployed bytes that were never reviewed here.\n")

      assert {:error, message} = SopGate.verify_adoption()
      assert {:ok, adopted} = SopGate.adopted_digest()

      # Both digests are named: which bytes are being served, and which were
      # reviewed. An operator has to be able to tell those apart to act.
      assert message =~ adopted

      assert message =~
               "sha256:" <> sha256("1.0.0", "Deployed bytes that were never reviewed here.\n")

      assert message =~ path
    end

    test "an unreadable SOP path is refused rather than skipped", %{path: path} do
      File.rm_rf!(Path.dirname(path))

      assert {:error, message} = SopGate.verify_adoption()
      assert message =~ "cannot read configured Systemwide SOP"
    end
  end

  defp write(path, nil, body), do: File.write!(path, body)

  defp write(path, version, body),
    do: File.write!(path, frontmatter(version) <> body)

  defp frontmatter(version), do: "---\nsop_id: systemwide-sop\nversion: #{version}\n---\n\n"

  defp sha256(version, body),
    do: :crypto.hash(:sha256, frontmatter(version) <> body) |> Base.encode16(case: :lower)

  # The shape `verify/1` reads off a task row.
  defp gate(ack), do: Map.put(ack, :sop_gate_required, true)
end
