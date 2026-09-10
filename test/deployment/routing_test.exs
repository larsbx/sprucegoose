defmodule SpruceGoose.Deployment.RoutingTest do
  use ExUnit.Case, async: true

  alias SpruceGoose.Deployment.Routing

  @now ~U[2026-07-31 12:00:00Z]

  defp expected do
    %{
      hostname: "accounta.bot",
      address: "178.156.142.163",
      upstream: "127.0.0.1:17777"
    }
  end

  defp observation(overrides \\ %{}) do
    Map.merge(
      %{
        observed_at: @now,
        hostname: "accounta.bot",
        resolved_addresses: ["178.156.142.163"],
        certificate: %{
          not_after: ~U[2026-10-07 04:57:17Z],
          sans: ["accounta.bot"],
          trusted: true
        },
        route: %{upstream: "127.0.0.1:17777", state: "active"},
        recovery: %{restore_verified: true, config_backup: "20260726T161116Z"}
      },
      overrides
    )
  end

  test "a fully verified routing boundary is ready" do
    assert {:ok, :routing_ready} = Routing.evaluate(observation(), expected(), @now)
  end

  test "routing policy and required observations cannot be omitted" do
    assert :ok = Routing.check_requirement({:required, expected()}, observation(), @now)

    assert {:error, :routing_observation_required} =
             Routing.check_requirement({:required, expected()}, nil, @now)

    for requirement <- [nil, false, %{}, :optional] do
      assert {:error, :invalid_routing_requirement} =
               Routing.check_requirement(requirement, nil, @now)
    end

    assert :ok = Routing.check_requirement(:unrouted, nil, @now)

    assert {:error, :invalid_routing_requirement} =
             Routing.check_requirement(:unrouted, observation(), @now)

    assert {:error, :invalid_routing_requirement} =
             Routing.check_requirement({:required, expected()}, "malformed", @now)

    assert {:error, {:routing_unsafe, reasons}} =
             Routing.check_requirement(
               {:required, expected()},
               observation(%{observed_at: DateTime.add(@now, -901)}),
               @now
             )

    assert :observation_stale in reasons
  end

  test "freshness boundaries retain subsecond precision" do
    assert {:ok, :routing_ready} =
             Routing.evaluate(
               observation(%{observed_at: DateTime.add(@now, -900)}),
               expected(),
               @now
             )

    for {delta, reason} <- [{1, :observation_in_future}, {-900_000_001, :observation_stale}] do
      assert {:error, failures} =
               Routing.evaluate(
                 observation(%{observed_at: DateTime.add(@now, delta, :microsecond)}),
                 expected(),
                 @now
               )

      assert reason in failures
    end
  end

  test "stale, undated, and future observations are refused" do
    stale = observation(%{observed_at: DateTime.add(@now, -901, :second)})
    assert {:error, failures} = Routing.evaluate(stale, expected(), @now)
    assert :observation_stale in failures

    assert {:error, failures} =
             Routing.evaluate(observation(%{observed_at: nil}), expected(), @now)

    assert :observation_undated in failures

    future = observation(%{observed_at: DateTime.add(@now, 60, :second)})
    assert {:error, failures} = Routing.evaluate(future, expected(), @now)
    assert :observation_in_future in failures

    # A just-fresh observation is still acceptable at the boundary.
    fresh = observation(%{observed_at: DateTime.add(@now, -899, :second)})
    assert {:ok, :routing_ready} = Routing.evaluate(fresh, expected(), @now)
  end

  test "DNS must resolve to exactly the declared deployment address" do
    assert {:error, failures} =
             Routing.evaluate(observation(%{resolved_addresses: []}), expected(), @now)

    assert :dns_unresolved in failures

    assert {:error, failures} =
             Routing.evaluate(
               observation(%{resolved_addresses: ["203.0.113.10"]}),
               expected(),
               @now
             )

    assert :dns_target_mismatch in failures

    # A stray additional record is a split-brain risk, not a pass.
    assert {:error, failures} =
             Routing.evaluate(
               observation(%{resolved_addresses: ["178.156.142.163", "203.0.113.10"]}),
               expected(),
               @now
             )

    assert :dns_extra_addresses in failures

    assert {:error, failures} =
             Routing.evaluate(observation(), Map.delete(expected(), :address), @now)

    assert :dns_target_undeclared in failures
  end

  test "certificate must be trusted, cover the hostname, and not be near expiry" do
    untrusted = observation(%{certificate: %{cert() | trusted: false}})
    assert {:error, failures} = Routing.evaluate(untrusted, expected(), @now)
    assert :certificate_untrusted in failures

    uncovered = observation(%{certificate: %{cert() | sans: ["other.example"]}})
    assert {:error, failures} = Routing.evaluate(uncovered, expected(), @now)
    assert :certificate_hostname_uncovered in failures

    expired = observation(%{certificate: %{cert() | not_after: DateTime.add(@now, -1, :day)}})
    assert {:error, failures} = Routing.evaluate(expired, expected(), @now)
    assert :certificate_expired in failures

    # Renewal headroom: a cert valid for less than the floor is refused early.
    soon = observation(%{certificate: %{cert() | not_after: DateTime.add(@now, 20, :day)}})
    assert {:error, failures} = Routing.evaluate(soon, expected(), @now)
    assert :certificate_expiring_soon in failures

    ok = observation(%{certificate: %{cert() | not_after: DateTime.add(@now, 22, :day)}})
    assert {:ok, :routing_ready} = Routing.evaluate(ok, expected(), @now)

    assert {:error, failures} =
             Routing.evaluate(observation(%{certificate: nil}), expected(), @now)

    assert :certificate_unverified in failures
  end

  test "route must point at the declared upstream and be active" do
    assert {:error, failures} =
             Routing.evaluate(
               observation(%{route: %{upstream: "127.0.0.1:9999", state: "active"}}),
               expected(),
               @now
             )

    assert :route_upstream_mismatch in failures

    assert {:error, failures} =
             Routing.evaluate(
               observation(%{route: %{upstream: "127.0.0.1:17777", state: "inactive"}}),
               expected(),
               @now
             )

    assert :route_upstream_not_active in failures

    assert {:error, failures} = Routing.evaluate(observation(%{route: nil}), expected(), @now)
    assert :route_unverified in failures
  end

  test "recovery evidence is required, not assumed" do
    assert {:error, failures} =
             Routing.evaluate(observation(%{recovery: nil}), expected(), @now)

    assert :recovery_unverified in failures

    assert {:error, failures} =
             Routing.evaluate(
               observation(%{recovery: %{restore_verified: false}}),
               expected(),
               @now
             )

    assert :recovery_restore_unverified in failures

    assert {:error, failures} =
             Routing.evaluate(
               observation(%{recovery: %{restore_verified: true}}),
               expected(),
               @now
             )

    assert :recovery_config_backup_missing in failures
  end

  test "hostname confusion between observation and target fails closed" do
    assert {:error, failures} =
             Routing.evaluate(observation(%{hostname: "evil.example"}), expected(), @now)

    assert :hostname_mismatch in failures
  end

  test "all failures are reported together rather than only the first" do
    broken =
      observation(%{
        resolved_addresses: ["203.0.113.10"],
        certificate: %{cert() | trusted: false},
        route: nil,
        recovery: nil
      })

    assert {:error, failures} = Routing.evaluate(broken, expected(), @now)

    for expected_failure <- [
          :dns_target_mismatch,
          :certificate_untrusted,
          :route_unverified,
          :recovery_unverified
        ] do
      assert expected_failure in failures
    end
  end

  test "malformed input is refused instead of coerced" do
    assert {:error, [:invalid_observation]} = Routing.evaluate(nil, expected(), @now)
    assert {:error, [:invalid_observation]} = Routing.evaluate(observation(), nil, @now)
    assert {:error, [:invalid_observation]} = Routing.evaluate("string", expected(), @now)
  end

  test "module performs no DNS, TLS, or web-server mutation" do
    source = File.read!("lib/spruce_goose/deployment/routing.ex")

    for forbidden <- [
          "System.cmd",
          ":os.cmd",
          "Port.open",
          "HTTPoison",
          ":httpc",
          "caddy",
          "reload",
          "certbot"
        ] do
      refute source =~ forbidden
    end

    exported = Routing.__info__(:functions) |> Keyword.keys() |> Enum.map(&Atom.to_string/1)

    refute Enum.any?(exported, fn name ->
             String.contains?(name, ["apply", "write", "issue", "renew", "reload", "deploy"])
           end)
  end

  defp cert do
    %{not_after: ~U[2026-10-07 04:57:17Z], sans: ["accounta.bot"], trusted: true}
  end
end
