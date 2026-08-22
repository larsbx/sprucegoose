defmodule SpruceGoose.Kernel.Constitution do
  @moduledoc """
  One immutable constitutional path from exact roots to an unexecuted effect intent.

  This module establishes typed, content-addressed reasoning artifacts. It does
  not persist them, append historical events, or execute effects.
  """

  alias SpruceGoose.Kernel.{Canonical, ContentID}

  @required_roots [
    :ontology,
    :schema,
    :norm,
    :policy,
    :grant_epoch,
    :agent_charter,
    :interpreter,
    :evidence_policy
  ]
  @allowed_actions ["verify_artifact"]

  defmodule RootSet do
    @enforce_keys [:id, :roots]
    defstruct @enforce_keys
  end

  defmodule OntologyVersion do
    @enforce_keys [
      :id,
      :root_set_id,
      :ontology_id,
      :schema_id,
      :defined_predicates,
      :bound_referents
    ]
    defstruct @enforce_keys
  end

  defmodule Proposition do
    @enforce_keys [:id, :root_set_id, :ontology_version_id, :predicate, :referent, :input_id]
    defstruct @enforce_keys
  end

  defmodule Evidence do
    @enforce_keys [:id, :root_set_id, :proposition_id, :observation_id, :status]
    defstruct @enforce_keys
  end

  defmodule Claim do
    @enforce_keys [:id, :root_set_id, :proposition_id, :evidence_id, :supported?]
    defstruct @enforce_keys
  end

  defmodule Justification do
    @enforce_keys [:id, :root_set_id, :claim_id, :evidence_policy_id, :interpreter_id]
    defstruct @enforce_keys
  end

  defmodule Norm do
    @enforce_keys [
      :id,
      :root_set_id,
      :ontology_version_id,
      :norm_id,
      :policy_id,
      :ontology_compatible?
    ]
    defstruct @enforce_keys
  end

  defmodule Grant do
    @enforce_keys [
      :id,
      :root_set_id,
      :norm_id,
      :grant_epoch_id,
      :agent_charter_id,
      :subject,
      :action,
      :authority,
      :expires_at
    ]
    defstruct @enforce_keys
  end

  defmodule Resolution do
    @enforce_keys [
      :id,
      :root_set_id,
      :justification_id,
      :norm_id,
      :grant_id,
      :conflicts,
      :outcome
    ]
    defstruct @enforce_keys
  end

  defmodule Authorization do
    @enforce_keys [:id, :root_set_id, :resolution_id, :subject, :action]
    defstruct @enforce_keys
  end

  defmodule EffectIntent do
    @enforce_keys [
      :id,
      :root_set_id,
      :authorization_id,
      :subject,
      :action,
      :referent,
      :executed?
    ]
    defstruct @enforce_keys
  end

  defmodule Path do
    @enforce_keys [
      :root_set,
      :ontology_version,
      :proposition,
      :evidence,
      :claim,
      :justification,
      :norm,
      :grant,
      :resolution,
      :authorization,
      :effect_intent
    ]
    defstruct @enforce_keys
  end

  @spec required_roots() :: [atom()]
  def required_roots, do: @required_roots

  @spec authorize(map(), map()) :: {:ok, Path.t()} | {:error, term()}
  def authorize(roots, request) when is_map(roots) and is_map(request) do
    with :ok <- validate_roots(roots),
         :ok <- validate_request(request),
         :ok <- defined_predicate?(request),
         :ok <- bound_referent?(request),
         :ok <- supported_claim?(request),
         :ok <- accepted_evidence?(request),
         :ok <- compatible_norm?(request),
         :ok <- current_grant?(roots, request),
         :ok <- sufficient_authority?(request),
         :ok <- licensed_effect?(request),
         :ok <- unexpired_grant?(request),
         :ok <- conflict_free?(request) do
      root_set = seal(RootSet, %{roots: roots})

      ontology_version =
        seal(OntologyVersion, %{
          root_set_id: root_set.id,
          ontology_id: roots.ontology,
          schema_id: roots.schema,
          defined_predicates: request.defined_predicates,
          bound_referents: request.bound_referents
        })

      proposition =
        seal(Proposition, %{
          root_set_id: root_set.id,
          ontology_version_id: ontology_version.id,
          predicate: request.predicate,
          referent: request.referent,
          input_id: request.input_id
        })

      evidence =
        seal(Evidence, %{
          root_set_id: root_set.id,
          proposition_id: proposition.id,
          observation_id: request.observation_id,
          status: request.evidence_status
        })

      claim =
        seal(Claim, %{
          root_set_id: root_set.id,
          proposition_id: proposition.id,
          evidence_id: evidence.id,
          supported?: request.claim_supported?
        })

      justification =
        seal(Justification, %{
          root_set_id: root_set.id,
          claim_id: claim.id,
          evidence_policy_id: roots.evidence_policy,
          interpreter_id: roots.interpreter
        })

      norm =
        seal(Norm, %{
          root_set_id: root_set.id,
          ontology_version_id: ontology_version.id,
          norm_id: roots.norm,
          policy_id: roots.policy,
          ontology_compatible?: request.ontology_norm_compatible?
        })

      grant =
        seal(Grant, %{
          root_set_id: root_set.id,
          norm_id: norm.id,
          grant_epoch_id: request.grant_epoch_id,
          agent_charter_id: roots.agent_charter,
          subject: request.grant_subject,
          action: request.grant_action,
          authority: request.authority,
          expires_at: request.expires_at
        })

      resolution =
        seal(Resolution, %{
          root_set_id: root_set.id,
          justification_id: justification.id,
          norm_id: norm.id,
          grant_id: grant.id,
          conflicts: request.conflicts,
          outcome: :authorized
        })

      authorization =
        seal(Authorization, %{
          root_set_id: root_set.id,
          resolution_id: resolution.id,
          subject: request.subject,
          action: request.action
        })

      effect_intent =
        seal(EffectIntent, %{
          root_set_id: root_set.id,
          authorization_id: authorization.id,
          subject: request.subject,
          action: request.action,
          referent: request.referent,
          executed?: false
        })

      {:ok,
       struct!(Path, %{
         root_set: root_set,
         ontology_version: ontology_version,
         proposition: proposition,
         evidence: evidence,
         claim: claim,
         justification: justification,
         norm: norm,
         grant: grant,
         resolution: resolution,
         authorization: authorization,
         effect_intent: effect_intent
       })}
    end
  end

  def authorize(_roots, _request), do: {:error, :invalid_constitutional_input}

  @spec verify(Path.t(), map(), DateTime.t()) :: :ok | {:error, term()}
  def verify(%Path{} = path, roots, %DateTime{} = now) do
    request = %{
      subject: path.effect_intent.subject,
      action: path.effect_intent.action,
      predicate: path.proposition.predicate,
      referent: path.effect_intent.referent,
      defined_predicates: path.ontology_version.defined_predicates,
      bound_referents: path.ontology_version.bound_referents,
      observation_id: path.evidence.observation_id,
      input_id: path.proposition.input_id,
      claim_supported?: path.claim.supported?,
      evidence_status: path.evidence.status,
      ontology_norm_compatible?: path.norm.ontology_compatible?,
      authority: path.grant.authority,
      conflicts: path.resolution.conflicts,
      grant_subject: path.grant.subject,
      grant_action: path.grant.action,
      grant_epoch_id: path.grant.grant_epoch_id,
      expires_at: path.grant.expires_at,
      now: now
    }

    case authorize(roots, request) do
      {:ok, ^path} -> :ok
      {:ok, _expected} -> {:error, :substituted_artifact}
      error -> error
    end
  end

  def verify(_path, _roots, _now), do: {:error, :invalid_constitutional_path}

  defp validate_roots(roots) do
    Enum.find_value(@required_roots, :ok, fn root ->
      case Map.fetch(roots, root) do
        {:ok, %ContentID{algorithm: :sha256}} -> false
        {:ok, _invalid} -> {:error, {:invalid_root, root}}
        :error -> {:error, {:missing_root, root}}
      end
    end)
  end

  defp validate_request(request) do
    valid =
      Enum.all?(
        [:subject, :action, :predicate, :referent, :grant_subject, :grant_action],
        &(is_binary(Map.get(request, &1)) and Map.get(request, &1) != "")
      ) and match?(%ContentID{algorithm: :sha256}, Map.get(request, :observation_id)) and
        match?(%ContentID{algorithm: :sha256}, Map.get(request, :input_id)) and
        is_list(Map.get(request, :defined_predicates)) and
        is_list(Map.get(request, :bound_referents)) and
        is_boolean(Map.get(request, :claim_supported?)) and
        Map.get(request, :evidence_status) in [:accepted, :contested] and
        is_boolean(Map.get(request, :ontology_norm_compatible?)) and
        Map.get(request, :authority) in [:sufficient, :insufficient] and
        is_list(Map.get(request, :conflicts)) and
        match?(%ContentID{algorithm: :sha256}, Map.get(request, :grant_epoch_id)) and
        match?(%DateTime{}, Map.get(request, :expires_at)) and
        match?(%DateTime{}, Map.get(request, :now))

    cond do
      not Map.has_key?(request, :input_id) -> {:error, :nondeterministic_input}
      valid -> :ok
      true -> {:error, :invalid_constitutional_input}
    end
  end

  defp defined_predicate?(request) do
    if request.predicate in request.defined_predicates,
      do: :ok,
      else: {:error, :undefined_predicate}
  end

  defp bound_referent?(request) do
    if request.referent in request.bound_referents, do: :ok, else: {:error, :unbound_referent}
  end

  defp supported_claim?(%{claim_supported?: true}), do: :ok
  defp supported_claim?(_request), do: {:error, :unsupported_claim}

  defp accepted_evidence?(%{evidence_status: :accepted}), do: :ok
  defp accepted_evidence?(_request), do: {:error, :contested_evidence}

  defp compatible_norm?(%{ontology_norm_compatible?: true}), do: :ok
  defp compatible_norm?(_request), do: {:error, :incompatible_ontology_and_norm}

  defp current_grant?(roots, request) do
    if roots.grant_epoch == request.grant_epoch_id, do: :ok, else: {:error, :stale_grant}
  end

  defp sufficient_authority?(%{authority: :sufficient}), do: :ok
  defp sufficient_authority?(_request), do: {:error, :insufficient_authority}

  defp licensed_effect?(request) do
    if request.action in @allowed_actions and request.grant_action in @allowed_actions and
         request.subject == request.grant_subject and request.action == request.grant_action,
       do: :ok,
       else: {:error, :unauthorized_effect}
  end

  defp unexpired_grant?(request) do
    if DateTime.compare(request.now, request.expires_at) == :lt,
      do: :ok,
      else: {:error, :expired_grant}
  end

  defp conflict_free?(%{conflicts: []}), do: :ok
  defp conflict_free?(_request), do: {:error, :unresolved_conflict}

  defp seal(module, attrs) do
    {:ok, bytes} = attrs |> canonical_value() |> Canonical.encode()
    {:ok, id} = ContentID.derive(:sha256, Atom.to_string(module) <> "\0" <> bytes)
    struct!(module, Map.put(attrs, :id, id))
  end

  defp canonical_value(%ContentID{algorithm: algorithm, digest: digest}),
    do: Atom.to_string(algorithm) <> ":" <> digest

  defp canonical_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp canonical_value(value) when is_atom(value), do: Atom.to_string(value)

  defp canonical_value(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), canonical_value(item)} end)
  end

  defp canonical_value(value) when is_list(value), do: Enum.map(value, &canonical_value/1)
  defp canonical_value(value), do: value
end
