defmodule SpruceGoose.Deployment.PreviewTest do
  use ExUnit.Case, async: true

  alias SpruceGoose.Deployment.Preview

  @now ~U[2026-07-31 12:00:00Z]
  @recovery %{recovery: %{restore_verified: true}}

  defp preview(overrides \\ %{}) do
    Map.merge(
      %{
        id: "prev-1",
        project: "accountabot",
        environment: "preview",
        state: :cancelled,
        terminal_at: DateTime.add(@now, -30 * 86_400, :second),
        pinned: false,
        active_references: 0
      },
      overrides
    )
  end

  # A cohort old and large enough that min-retained protection is satisfied by
  # other members, so the subject under test is judged on its own merits.
  defp cohort(subject) do
    filler =
      for i <- 1..3 do
        preview(%{
          id: "filler-#{i}",
          terminal_at: DateTime.add(@now, -i, :second)
        })
      end

    [subject | filler]
  end

  defp eligible_ids(previews, policy \\ @recovery) do
    {:ok, %{eligible: eligible}} = Preview.select_reclaimable(previews, policy, @now)
    Enum.map(eligible, & &1.id) |> MapSet.new()
  end

  defp retained_reason(previews, id, policy \\ @recovery) do
    {:ok, %{retained: retained}} = Preview.select_reclaimable(previews, policy, @now)
    Enum.find_value(retained, fn {p, reason} -> if p.id == id, do: reason end)
  end

  test "an old terminal preview beyond TTL and grace is reclaimable" do
    assert "prev-1" in eligible_ids(cohort(preview()))
  end

  test "reclamation is refused entirely without verified restore evidence" do
    assert {:error, :recovery_unverified} =
             Preview.select_reclaimable(cohort(preview()), %{}, @now)

    assert {:error, :recovery_restore_unverified} =
             Preview.select_reclaimable(
               cohort(preview()),
               %{recovery: %{restore_verified: false}},
               @now
             )
  end

  test "only the preview environment may ever be reclaimed" do
    for env <- ["staging", "production", "prod", nil, ""] do
      subject = preview(%{environment: env})
      refute "prev-1" in eligible_ids(cohort(subject))
      assert retained_reason(cohort(subject), "prev-1") == :not_a_preview_environment
    end
  end

  test "pinned previews are never reclaimable regardless of age" do
    subject = preview(%{pinned: true, terminal_at: DateTime.add(@now, -3650 * 86_400, :second)})
    refute "prev-1" in eligible_ids(cohort(subject))
    assert retained_reason(cohort(subject), "prev-1") == :pinned
  end

  test "previews still referenced by an active deployment are retained" do
    subject = preview(%{active_references: 1})
    assert retained_reason(cohort(subject), "prev-1") == :referenced_by_active_deployment

    # A non-integer reference count is ambiguous and must not permit deletion.
    ambiguous = preview(%{active_references: "unknown"})
    assert retained_reason(cohort(ambiguous), "prev-1") == :referenced_by_active_deployment
  end

  test "non-terminal previews are retained even when old" do
    for state <- [:queued, :building, :staged, :deploying, :verifying, :rolling_back] do
      subject = preview(%{state: state})
      assert retained_reason(cohort(subject), "prev-1") == :not_terminal
    end
  end

  test "previews inside the retention window are retained" do
    # TTL 72h + grace 24h = 96h. One hour short must be retained.
    subject = preview(%{terminal_at: DateTime.add(@now, -95 * 3_600, :second)})
    assert retained_reason(cohort(subject), "prev-1") == :within_retention_window

    older = preview(%{terminal_at: DateTime.add(@now, -97 * 3_600, :second)})
    assert "prev-1" in eligible_ids(cohort(older))
  end

  test "undated and future-dated previews are retained, never deleted" do
    assert retained_reason(cohort(preview(%{terminal_at: nil})), "prev-1") == :undated

    future = preview(%{terminal_at: DateTime.add(@now, 3_600, :second)})
    assert retained_reason(cohort(future), "prev-1") == :terminal_in_future
  end

  test "malformed previews are retained rather than coerced" do
    for bad <- [%{}, %{id: "", project: "p"}, %{id: "x", project: ""}, %{project: "p"}] do
      {:ok, %{eligible: eligible, retained: retained}} =
        Preview.select_reclaimable([bad], @recovery, @now)

      assert eligible == []
      assert [{_, :malformed_preview}] = retained
    end

    {:ok, %{eligible: [], retained: [{_, :malformed_preview}]}} =
      Preview.select_reclaimable(["not-a-map"], @recovery, @now)
  end

  test "the newest previews per project are always retained" do
    previews =
      for i <- 1..6 do
        preview(%{
          id: "p-#{i}",
          # p-1 newest ... p-6 oldest, all far beyond the retention window
          terminal_at: DateTime.add(@now, -(100 + i) * 3_600, :second)
        })
      end

    eligible = eligible_ids(previews)

    # Three newest protected by identity, remainder reclaimable.
    for kept <- ["p-1", "p-2", "p-3"], do: refute(kept in eligible)
    for reclaimable <- ["p-4", "p-5", "p-6"], do: assert(reclaimable in eligible)

    assert retained_reason(previews, "p-1") == :within_minimum_retained
  end

  test "minimum retention is applied per project, so one project cannot strip another" do
    previews =
      for project <- ["alpha", "beta"], i <- 1..4 do
        preview(%{
          id: "#{project}-#{i}",
          project: project,
          terminal_at: DateTime.add(@now, -(100 + i) * 3_600, :second)
        })
      end

    eligible = eligible_ids(previews)

    # Each project keeps its own three newest; only the fourth is reclaimable.
    assert "alpha-4" in eligible
    assert "beta-4" in eligible

    for kept <- ["alpha-1", "alpha-2", "alpha-3", "beta-1", "beta-2", "beta-3"] do
      refute kept in eligible
    end
  end

  test "a project with too few previews is never emptied" do
    previews =
      for i <- 1..3 do
        preview(%{id: "only-#{i}", terminal_at: DateTime.add(@now, -3650 * 86_400, :second)})
      end

    assert eligible_ids(previews) == MapSet.new()
  end

  test "policy overrides are honoured but nonsense values fall back to safe defaults" do
    subject = preview(%{terminal_at: DateTime.add(@now, -10 * 3_600, :second)})

    # Default 96h window retains a 10h-old preview.
    assert retained_reason(cohort(subject), "prev-1") == :within_retention_window

    # An explicit shorter window makes it reclaimable.
    short = Map.merge(@recovery, %{ttl_seconds: 3_600, grace_seconds: 3_600})
    assert "prev-1" in eligible_ids(cohort(subject), short)

    # Zero, negative, and non-integer windows must not become "delete everything".
    for bad <- [0, -1, "0", nil] do
      policy = Map.merge(@recovery, %{ttl_seconds: bad, grace_seconds: bad})
      assert retained_reason(cohort(subject), "prev-1", policy) == :within_retention_window
    end

    # A zero minimum-retained must not disable per-project protection.
    policy = Map.merge(@recovery, %{min_retained_per_project: 0})

    old =
      for i <- 1..5,
          do:
            preview(%{id: "o-#{i}", terminal_at: DateTime.add(@now, -(200 + i) * 3_600, :second)})

    eligible = eligible_ids(old, policy)
    assert MapSet.size(eligible) == 2
  end

  test "the final guard re-evaluates against the live cohort" do
    subject = preview()
    previews = cohort(subject)

    assert :ok = Preview.assert_reclaimable(subject, previews, @recovery, @now)

    # Same subject, but now pinned: the guard must refuse even though a stale
    # batch decision may have listed it as eligible.
    pinned = preview(%{pinned: true})
    assert {:error, :pinned} = Preview.assert_reclaimable(pinned, cohort(pinned), @recovery, @now)

    # A subject that is not part of the supplied cohort cannot be authorized.
    assert {:error, :not_in_cohort} =
             Preview.assert_reclaimable(subject, cohort(preview(%{id: "other"})), @recovery, @now)

    # Without recovery evidence the guard refuses.
    assert {:error, :recovery_unverified} =
             Preview.assert_reclaimable(subject, previews, %{}, @now)
  end

  test "unknown pin and reference status never permits reclamation" do
    for pinned <- [nil, "false", 0] do
      subject = preview(%{pinned: pinned})
      assert retained_reason(cohort(subject), "prev-1") == :pin_status_unknown
    end

    for count <- [nil, -1, "0"] do
      subject = preview(%{active_references: count})
      assert retained_reason(cohort(subject), "prev-1") == :referenced_by_active_deployment
    end
  end

  test "duplicate IDs and mismatched subject observations fail closed" do
    subject = preview()

    assert {:error, :ambiguous_cohort} =
             Preview.select_reclaimable([subject | cohort(subject)], @recovery, @now)

    assert {:error, :ambiguous_cohort} =
             Preview.select_reclaimable([%{id: subject.id} | cohort(subject)], @recovery, @now)

    assert {:error, :cohort_mismatch} =
             Preview.assert_reclaimable(
               %{subject | pinned: true},
               cohort(subject),
               @recovery,
               @now
             )
  end

  test "other environments cannot occupy preview minimum-retention slots" do
    subject = preview()
    others = Enum.map(tl(cohort(subject)), &%{&1 | environment: "production"})
    assert retained_reason([subject | others], "prev-1") == :within_minimum_retained
  end

  test "module deletes nothing and exposes no destructive operation" do
    source = File.read!("lib/spruce_goose/deployment/preview.ex")

    for forbidden <- [
          "System.cmd",
          ":os.cmd",
          "Port.open",
          "DROP",
          "DELETE FROM",
          "TRUNCATE",
          "File.rm"
        ] do
      refute source =~ forbidden
    end

    exported = Preview.__info__(:functions) |> Keyword.keys() |> Enum.map(&Atom.to_string/1)

    refute Enum.any?(exported, fn name ->
             String.contains?(name, ["delete", "destroy", "reclaim!", "purge", "prune", "remove"])
           end)
  end

  test "invalid request shapes are refused" do
    assert {:error, :invalid_retention_request} =
             Preview.select_reclaimable("not-a-list", @recovery, @now)

    assert {:error, :invalid_retention_request} =
             Preview.select_reclaimable([preview()], "not-a-map", @now)
  end
end
