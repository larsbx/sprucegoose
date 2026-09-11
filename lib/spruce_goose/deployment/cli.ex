defmodule SpruceGoose.Deployment.CLI do
  @moduledoc """
  The `deployment` command family: thin, actor-bound verbs over the domain.

  Every mutation delegates to `SpruceGoose.Deployment`; every read is an
  authorized Ash read rendered as a projection. Reads append nothing.
  """

  alias SpruceGoose.{Authz, Deployment}
  alias SpruceGoose.Deployment.{Executor, Ledger, Operation, Record, Release}

  @artifact_flags [archive: :archive, files: :files, image: :image]

  def run(:accept_release, %{project: project, attrs: attrs}) do
    with {:ok, release} <- Deployment.accept_release(project, attrs),
         do: {:ok, release_json(release)}
  end

  def run(:create, %{release_id: release_id, environment: environment, pinned: pinned}) do
    with {:ok, record} <- Deployment.create(release_id, environment, pinned: pinned),
         do: {:ok, record_json(record)}
  end

  def run(:stage, %{deployment_id: id}),
    do: with({:ok, record} <- Deployment.stage(id), do: {:ok, record_json(record)})

  def run(:cancel, %{deployment_id: id, reason: reason}),
    do: with({:ok, record} <- Deployment.cancel(id, reason), do: {:ok, record_json(record)})

  def run(:observe_health, %{deployment_id: id, status: status, detail: detail}),
    do:
      with(
        {:ok, record} <- Deployment.observe_health(id, status, detail),
        do: {:ok, record_json(record)}
      )

  def run(:authorize, %{deployment_id: id, attrs: attrs}),
    do:
      with(
        {:ok, authorization} <- Deployment.authorize(id, attrs),
        do: {:ok, authorization_json(authorization)}
      )

  def run(:request, %{authorization_id: id, opts: opts}),
    do:
      with({:ok, operation} <- Deployment.request(id, opts), do: {:ok, operation_json(operation)})

  # An operation whose executor job was exhausted or discarded is re-queued;
  # a completed operation is exactly what one_operation_per_authorization refuses to repeat.
  def run(:reconcile, %{operation_id: id}) do
    with {:ok, %Operation{phase: phase} = operation} <-
           Authz.read_one(Operation, operation_id: id),
         :ok <- if(phase == :completed, do: {:error, "operation already completed"}, else: :ok),
         # AUTHORIZATION: the actor-bound read above established authority over this operation before its job is re-queued.
         {:ok, _job} <- %{operation_id: operation.operation_id} |> Executor.new() |> Oban.insert() do
      {:ok, operation_json(operation)}
    end
  end

  def run(:show, %{deployment_id: id}) do
    with {:ok, record} <- Authz.read_one(Record, deployment_id: id),
         {:ok, operations} <-
           Operation |> Ash.Query.filter_input(deployment_id: record.id) |> Authz.read(),
         parity <- Deployment.parity(id) do
      {:ok,
       record
       |> record_json()
       |> Map.merge(%{
         operations: Enum.map(operations, &operation_json/1),
         parity: parity_json(parity)
       })}
    end
  end

  def run(:list, %{project: nil}),
    do:
      with(
        {:ok, records} <- Authz.read(Record),
        do: {:ok, %{deployments: Enum.map(records, &record_json/1)}}
      )

  def run(:list, %{project: key}) do
    with {:ok, records} <-
           Record |> Ash.Query.filter_input(release: [project: [key: key]]) |> Authz.read(),
         do: {:ok, %{deployments: Enum.map(records, &record_json/1)}}
  end

  def run(:events, %{deployment_id: id}) do
    with {:ok, _record} <- Authz.read_one(Record, deployment_id: id),
         {:ok, events} <- Ledger.read(id) do
      {:ok,
       %{
         deployment_id: id,
         events:
           Enum.map(
             events,
             &%{type: &1.event_type, identity: &1.identity.digest, payload: &1.payload}
           )
       }}
    end
  end

  @doc "Parse `deployment <verb> ...` into `{:deployment, verb, args}`."
  def parse(["release-accept", project | args]) do
    strict =
      [
        forge_instance: :string,
        repository: :string,
        commit: :string,
        pipeline_number: :integer,
        pipeline_digest: :string
      ] ++ Enum.map(@artifact_flags, fn {flag, _} -> {flag, :string} end)

    with {:ok, opts} <-
           options(
             args,
             strict,
             ~w(forge_instance repository commit pipeline_number pipeline_digest)a,
             "release-accept"
           ) do
      artifacts =
        for {flag, kind} <- @artifact_flags,
            digest = opts[flag],
            is_binary(digest),
            into: %{},
            do: {kind, digest}

      {:ok,
       {:deployment, :accept_release,
        %{
          project: project,
          attrs: %{
            forge_instance: opts[:forge_instance],
            repository: opts[:repository],
            source_commit: opts[:commit],
            pipeline_number: opts[:pipeline_number],
            pipeline_digest: opts[:pipeline_digest],
            artifacts: artifacts
          }
        }}}
    end
  end

  def parse(["create", release_id, environment | args])
      when environment in ~w(preview staging production) do
    with {:ok, opts} <- options(args, [pinned: :boolean], [], "create") do
      {:ok,
       {:deployment, :create,
        %{
          release_id: release_id,
          environment: String.to_existing_atom(environment),
          pinned: opts[:pinned] == true
        }}}
    end
  end

  def parse(["stage", id]), do: {:ok, {:deployment, :stage, %{deployment_id: id}}}

  def parse(["cancel", id, reason]),
    do: {:ok, {:deployment, :cancel, %{deployment_id: id, reason: reason}}}

  def parse(["observe-health", id, status | detail])
      when status in ~w(healthy unhealthy) and length(detail) <= 1,
      do:
        {:ok,
         {:deployment, :observe_health,
          %{
            deployment_id: id,
            status: String.to_existing_atom(status),
            detail: List.first(detail)
          }}}

  def parse(["authorize", id | args]) do
    with {:ok, opts} <-
           options(
             args,
             [action: :string, reference: :string, target: :string, ttl: :integer],
             [:action, :reference],
             "authorize"
           ),
         {:ok, action} <- operation_action(opts[:action]) do
      attrs = %{
        action: action,
        approval_reference: opts[:reference],
        target_deployment_id: opts[:target]
      }

      attrs = if opts[:ttl], do: Map.put(attrs, :ttl_seconds, opts[:ttl]), else: attrs
      {:ok, {:deployment, :authorize, %{deployment_id: id, attrs: attrs}}}
    end
  end

  def parse(["request", id | args]) do
    with {:ok, opts} <-
           options(args, [routing: :string, recovery_verified: :boolean], [], "request"),
         {:ok, routing} <- routing(opts[:routing]) do
      request_opts =
        Enum.reject(
          [
            routing: routing,
            policy: if(opts[:recovery_verified], do: %{recovery: %{restore_verified: true}})
          ],
          fn {_, value} -> is_nil(value) end
        )

      {:ok, {:deployment, :request, %{authorization_id: id, opts: request_opts}}}
    end
  end

  def parse(["reconcile", id]), do: {:ok, {:deployment, :reconcile, %{operation_id: id}}}
  def parse(["show", id]), do: {:ok, {:deployment, :show, %{deployment_id: id}}}
  def parse(["events", id]), do: {:ok, {:deployment, :events, %{deployment_id: id}}}

  def parse(["list" | args]) do
    with {:ok, opts} <- options(args, [project: :string], [], "list"),
         do: {:ok, {:deployment, :list, %{project: opts[:project]}}}
  end

  def parse(_), do: {:error, :usage}

  def usage do
    [
      "release-accept PROJECT --forge-instance ID --repository OWNER/REPO --commit OID --pipeline-number N --pipeline-digest SHA256 --archive sha256:HEX [--files sha256:HEX] [--image sha256:HEX]",
      "create RELEASE_ID preview|staging|production [--pinned]",
      "stage DEPLOYMENT_ID",
      "cancel DEPLOYMENT_ID REASON",
      "observe-health DEPLOYMENT_ID healthy|unhealthy [DETAIL]",
      "authorize DEPLOYMENT_ID --action execute_deploy|execute_rollback|execute_reclaim --reference REF [--target DEPLOYMENT_ID] [--ttl SECONDS]",
      "request AUTHORIZATION_ID [--routing JSON] [--recovery-verified]",
      "reconcile OPERATION_ID",
      "show DEPLOYMENT_ID",
      "list [--project KEY]",
      "events DEPLOYMENT_ID"
    ]
  end

  defp options(args, strict, required, verb) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: strict)

    if rest == [] and invalid == [] and Enum.all?(required, &Keyword.has_key?(opts, &1)),
      do: {:ok, opts},
      else: {:error, "invalid deployment #{verb} arguments"}
  end

  defp operation_action(name) do
    Enum.find_value(
      SpruceGoose.Deployment.Projection.operation_actions(),
      {:error, "invalid deployment action"},
      &if(Atom.to_string(&1) == name, do: {:ok, &1})
    )
  end

  # Routing evidence arrives as JSON from the observer; times are ISO 8601.
  defp routing(nil), do: {:ok, nil}

  defp routing(json) do
    with {:ok, %{"observation" => observation, "expected" => expected}}
         when is_map(observation) and is_map(expected) <- Jason.decode(json) do
      {:ok, %{observation: atomize(observation), expected: atomize(expected)}}
    else
      _ -> {:error, "invalid routing evidence; expected JSON with observation and expected"}
    end
  end

  @routing_keys ~w(observed_at hostname resolved_addresses certificate not_after sans trusted route upstream state recovery restore_verified config_backup address)

  defp atomize(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when key in @routing_keys -> {String.to_existing_atom(key), atomize(value)}
      {key, value} -> {key, atomize(value)}
    end)
  end

  defp atomize(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> value
    end
  end

  defp atomize(value), do: value

  defp release_json(%Release{} = release) do
    Map.take(release, [
      :release_id,
      :forge_instance,
      :repository,
      :source_commit,
      :pipeline_number,
      :pipeline_digest,
      :artifacts,
      :accepted_by,
      :inserted_at
    ])
  end

  defp record_json(%Record{} = record) do
    Map.take(record, [
      :deployment_id,
      :environment,
      :requires_routing,
      :state,
      :health_status,
      :health_detail,
      :cancellation_reason,
      :rollback_target_id,
      :pinned,
      :terminal_at,
      :reclaimed_at,
      :last_event,
      :inserted_at,
      :updated_at
    ])
  end

  defp authorization_json(authorization) do
    Map.take(authorization, [
      :authorization_id,
      :action,
      :target_deployment_id,
      :approved_by,
      :approval_reference,
      :issued_at,
      :expires_at
    ])
  end

  defp operation_json(%Operation{} = operation) do
    Map.take(operation, [
      :operation_id,
      :authorization_id,
      :action,
      :target_deployment_id,
      :phase,
      :outcome,
      :executor_id,
      :evidence_digest,
      :detail,
      :observation_count,
      :started_at,
      :completed_at
    ])
  end

  defp parity_json({:ok, :parity}), do: %{status: "parity"}

  defp parity_json({:error, {:parity_mismatch, mismatches}}),
    do: %{status: "mismatch", fields: Enum.map(mismatches, fn {f, _, _} -> f end)}

  defp parity_json({:error, reason}), do: %{status: "unreplayable", reason: inspect(reason)}
end
