defmodule SpruceGoose.Deployment.Routing do
  @moduledoc """
  Routing, TLS, and host-recovery *preconditions* for a deployment.

  This module reads and evaluates externally supplied observations. It issues no
  DNS write, no certificate request, no web-server restart, and no shell command.
  The existing web-server configuration, DNS zone, and ACME account on this host
  remain owned by their established operators; nothing here mutates them.

  Its job is to answer one question honestly: is the routing and recovery
  boundary currently safe to deploy behind? A missing, stale, or ambiguous
  observation is treated as unsafe, never as a pass.
  """

  @min_certificate_days 21
  @max_observation_age_seconds 900
  @required_upstream_states ["active"]

  @doc "Days of remaining certificate validity required before a deploy."
  def min_certificate_days, do: @min_certificate_days

  @doc """
  Check the routing requirement declared by deployment policy.

  The requirement must come from the authoritative deployment record, not an
  executor option. Only an explicit `:unrouted` policy with no observation skips
  routing checks. An omitted requirement or required observation fails closed.
  This checks evidence content and age; its provenance must be verified by the
  future admission boundary.
  """
  def check_requirement(requirement, observation, now \\ DateTime.utc_now())

  def check_requirement(:unrouted, nil, %DateTime{}), do: :ok

  def check_requirement({:required, %{} = expected}, %{} = observation, %DateTime{} = now) do
    case evaluate(observation, expected, now) do
      {:ok, :routing_ready} -> :ok
      {:error, reasons} -> {:error, {:routing_unsafe, reasons}}
    end
  end

  def check_requirement({:required, %{}}, nil, %DateTime{}),
    do: {:error, :routing_observation_required}

  def check_requirement(_, _, _), do: {:error, :invalid_routing_requirement}

  @doc """
  Evaluate whether the routing boundary is ready for a deployment.

  Requires the hostname to be covered by the certificate, the certificate to be
  trusted and comfortably unexpired, the route upstream to match the deployment
  target, and a recovery path to be present. Every failure is reported, so an
  operator sees the whole picture rather than the first tripped check.
  """
  def evaluate(observation, expected, now \\ DateTime.utc_now())

  def evaluate(%{} = observation, %{} = expected, %DateTime{} = now) do
    failures =
      []
      |> check_freshness(observation, now)
      |> check_hostname(observation, expected)
      |> check_dns(observation, expected)
      |> check_certificate(observation, expected, now)
      |> check_route(observation, expected)
      |> check_recovery(observation)
      |> Enum.reverse()

    case failures do
      [] -> {:ok, :routing_ready}
      failures -> {:error, failures}
    end
  end

  def evaluate(_, _, _), do: {:error, [:invalid_observation]}

  defp check_freshness(failures, observation, now) do
    case Map.get(observation, :observed_at) do
      %DateTime{} = observed_at ->
        age = DateTime.diff(now, observed_at, :microsecond)

        cond do
          age < 0 -> [:observation_in_future | failures]
          age > @max_observation_age_seconds * 1_000_000 -> [:observation_stale | failures]
          true -> failures
        end

      _ ->
        [:observation_undated | failures]
    end
  end

  defp check_hostname(failures, observation, expected) do
    case {Map.get(observation, :hostname), Map.get(expected, :hostname)} do
      {host, host} when is_binary(host) and host != "" -> failures
      _ -> [:hostname_mismatch | failures]
    end
  end

  defp check_dns(failures, observation, expected) do
    resolved = Map.get(observation, :resolved_addresses)
    intended = Map.get(expected, :address)

    cond do
      not is_list(resolved) or resolved == [] -> [:dns_unresolved | failures]
      not is_binary(intended) or intended == "" -> [:dns_target_undeclared | failures]
      resolved == [intended] -> failures
      intended in resolved -> [:dns_extra_addresses | failures]
      true -> [:dns_target_mismatch | failures]
    end
  end

  defp check_certificate(failures, observation, expected, now) do
    certificate = Map.get(observation, :certificate)
    hostname = Map.get(expected, :hostname)

    case certificate do
      %{not_after: %DateTime{} = not_after, sans: sans, trusted: trusted}
      when is_list(sans) and is_boolean(trusted) ->
        remaining_days = DateTime.diff(not_after, now, :second) / 86_400

        failures
        |> then(fn f -> if trusted, do: f, else: [:certificate_untrusted | f] end)
        |> then(fn f ->
          if hostname in sans, do: f, else: [:certificate_hostname_uncovered | f]
        end)
        |> then(fn f ->
          cond do
            remaining_days <= 0 -> [:certificate_expired | f]
            remaining_days < @min_certificate_days -> [:certificate_expiring_soon | f]
            true -> f
          end
        end)

      _ ->
        [:certificate_unverified | failures]
    end
  end

  defp check_route(failures, observation, expected) do
    route = Map.get(observation, :route)
    upstream = Map.get(expected, :upstream)

    case route do
      %{upstream: ^upstream, state: state} when is_binary(upstream) and upstream != "" ->
        if state in @required_upstream_states,
          do: failures,
          else: [:route_upstream_not_active | failures]

      %{upstream: _} ->
        [:route_upstream_mismatch | failures]

      _ ->
        [:route_unverified | failures]
    end
  end

  defp check_recovery(failures, observation) do
    case Map.get(observation, :recovery) do
      %{restore_verified: true, config_backup: backup} when is_binary(backup) and backup != "" ->
        failures

      %{restore_verified: true} ->
        [:recovery_config_backup_missing | failures]

      %{restore_verified: false} ->
        [:recovery_restore_unverified | failures]

      _ ->
        [:recovery_unverified | failures]
    end
  end
end
