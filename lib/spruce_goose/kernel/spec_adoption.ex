defmodule SpruceGoose.Kernel.SpecAdoption do
  @moduledoc """
  Adoption of an exact deontic specification, bound to a constitutional decision.

  This closes the gap named in `docs/deontic-spec-contract.md` section 8: the
  kernel could verify the constitutional path, certified events, permits, and
  receipts, but had no way to establish `ADOPTED`, so every deontic spec
  remained `DRAFT` or `CANDIDATE`.

  ## What adoption is here

  Adoption is not a new authority mechanism. It is the consumption of an
  `Authorization` that the existing constitutional path already produced. The
  path is traversed with the allowlisted `verify_artifact` action — adopting a
  spec *is* verifying exact artifact bytes — so the effect allowlist (A6) is
  not widened and `EffectIntent` stays inert (A7).

  ## What the candidate cannot do

  G1 forbids self-adoption. Nothing in the candidate payload is read to decide
  whether adoption succeeds: the spec identity is derived from the exact bytes
  supplied by the caller, and the authority comes from the `Authorization`
  struct built by `SpruceGoose.Kernel.Constitution`, which lives in the kernel
  and not in the document. A candidate may assert any state it likes about
  itself; `adopt/1` never looks.

  This is why `reject_self_declaration/1` exists as an explicit check rather
  than a comment. A payload that carries a lifecycle claim is refused outright,
  so a spec that *tries* to adopt itself fails loudly instead of having its
  claim silently ignored.

  ## Lifecycle

  G5 is monotonic:

      DRAFT -> CANDIDATE -> ADOPTED -> SUPERSEDED | REVOKED

  There is no path back to `ADOPTED`, and amendment is replacement (G6): new
  bytes produce a new identity requiring its own adoption.
  """

  alias SpruceGoose.Kernel.{CertifiedEvent, Constitution, ContentID}
  alias SpruceGoose.Kernel.Constitution.Authorization

  @stream "spec-adoption"
  @event_type "SpecAdopted"

  @states [:draft, :candidate, :adopted, :superseded, :revoked]
  @terminal [:superseded, :revoked]

  # Only these transitions exist. Anything absent refuses; there is no
  # permissive fallback and no route back into :adopted.
  @transitions %{
    draft: [:candidate],
    candidate: [:adopted],
    adopted: [:superseded, :revoked],
    superseded: [],
    revoked: []
  }

  # Lifecycle words a candidate must not assert about itself (G1). Compared
  # against the value, never the surrounding text.
  @lifecycle_claims ~w(adopted superseded revoked candidate)

  defmodule Adoption do
    @moduledoc "One immutable adoption binding exact bytes to a decision."

    @enforce_keys [
      :id,
      :spec_id,
      :roots,
      :authorization_id,
      :decision_ref,
      :grant_epoch_id,
      :state
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: ContentID.t(),
            spec_id: ContentID.t(),
            roots: map(),
            authorization_id: ContentID.t(),
            decision_ref: String.t(),
            grant_epoch_id: String.t(),
            state: atom()
          }
  end

  @spec states() :: [atom()]
  def states, do: @states

  @spec stream() :: String.t()
  def stream, do: @stream

  @doc """
  Adopt exact specification bytes under a verified constitutional authorization.

  Requires:

    * `:spec_bytes`     — the exact bytes being adopted (identity is derived,
                          never taken from a field the candidate controls)
    * `:authorization`  — an `Authorization` from `Constitution.authorize/2`
    * `:roots`          — the complete eight-root set
    * `:decision_ref`   — the human decision this adoption records
    * `:grant_epoch_id` — must equal the root set's grant epoch (A3)
    * `:prior_state`    — current lifecycle state; must be `:candidate` (G5)
    * `:payload`        — optional candidate metadata, checked for self-claims

  Returns the adoption and the certified event to append. It does not append:
  persistence is the caller's transaction so that P4's one-terminal-outcome
  discipline stays with the ledger.
  """
  @spec adopt(map()) :: {:ok, Adoption.t(), CertifiedEvent.t()} | {:error, term()}
  def adopt(attrs) when is_map(attrs) do
    with {:ok, bytes} <- fetch_bytes(attrs),
         {:ok, %Constitution.Path{} = path} <- fetch_path(attrs),
         authorization = path.authorization,
         {:ok, roots} <- fetch_roots(attrs),
         {:ok, decision_ref} <- fetch_decision_ref(attrs),
         {:ok, grant_epoch_id} <- fetch_string(attrs, :grant_epoch_id),
         :ok <- reject_self_declaration(Map.get(attrs, :payload, %{})),
         :ok <- transition_allowed(Map.get(attrs, :prior_state, :candidate), :adopted),
         :ok <- fresh_epoch(roots, grant_epoch_id),
         :ok <- bound_authorization(path, roots),
         {:ok, spec_id} <- ContentID.derive(:sha256, bytes),
         {:ok, adoption} <-
           seal(spec_id, roots, authorization, decision_ref, grant_epoch_id),
         {:ok, event} <- certify(adoption) do
      {:ok, adoption, event}
    end
  end

  def adopt(_attrs), do: {:error, :invalid_adoption_input}

  @doc """
  Verify an adoption against the exact bytes it claims to bind.

  This is the substitution-resistance check (D4). Re-deriving the identity from
  the bytes in hand and comparing is what makes swapping the document after
  adoption fail closed rather than pass silently.
  """
  @spec verify(Adoption.t(), binary(), map()) :: :ok | {:error, term()}
  def verify(%Adoption{} = adoption, bytes, roots) when is_binary(bytes) and is_map(roots) do
    with {:ok, derived} <- ContentID.derive(:sha256, bytes),
         :ok <- same_spec(adoption.spec_id, derived),
         :ok <- same_roots(adoption.roots, roots) do
      if adoption.state == :adopted, do: :ok, else: {:error, :not_adopted}
    end
  end

  def verify(_adoption, _bytes, _roots), do: {:error, :invalid_adoption_input}

  @doc """
  Move an adopted specification to a terminal state (G5).

  Monotonic: only `:superseded` and `:revoked` are reachable, and neither can
  return. A revoked or superseded root cannot authorize new work.
  """
  @spec retire(Adoption.t(), atom()) :: {:ok, Adoption.t()} | {:error, term()}
  def retire(%Adoption{} = adoption, next) when next in @terminal do
    with :ok <- transition_allowed(adoption.state, next) do
      {:ok, %{adoption | state: next}}
    end
  end

  def retire(%Adoption{}, _next), do: {:error, :invalid_lifecycle_transition}

  @doc "Whether an adoption may authorize new work. Only `:adopted` may."
  @spec may_authorize?(Adoption.t()) :: boolean()
  def may_authorize?(%Adoption{state: :adopted}), do: true
  def may_authorize?(%Adoption{}), do: false

  # ---- internals ---------------------------------------------------------

  defp fetch_bytes(attrs) do
    case Map.fetch(attrs, :spec_bytes) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > 0 -> {:ok, bytes}
      _ -> {:error, :missing_spec_bytes}
    end
  end

  # The whole constitutional path is required, not a bare Authorization. Taking
  # the path means the authorization's binding to its root set is guaranteed by
  # construction rather than re-derived here; duplicating the kernel's private
  # sealing logic would silently diverge the first time that logic changed.
  defp fetch_path(attrs) do
    case Map.fetch(attrs, :path) do
      {:ok, %Constitution.Path{authorization: %Authorization{}} = path} -> {:ok, path}
      _ -> {:error, :insufficient_authority}
    end
  end

  defp fetch_roots(attrs) do
    case Map.fetch(attrs, :roots) do
      {:ok, roots} when is_map(roots) -> validate_roots(roots)
      _ -> {:error, {:missing_root, :all}}
    end
  end

  defp fetch_decision_ref(attrs) do
    case fetch_string(attrs, :decision_ref) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:error, :missing_decision_reference}
    end
  end

  defp fetch_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  # D1: a label, filename, or branch is not an identity. Roots must be exact
  # content identities, matching what the constitutional path itself demands.
  defp validate_roots(roots) do
    Enum.reduce_while(Constitution.required_roots(), :ok, fn root, _acc ->
      case Map.fetch(roots, root) do
        {:ok, %ContentID{algorithm: :sha256}} -> {:cont, :ok}
        {:ok, _invalid} -> {:halt, {:error, {:invalid_root, root}}}
        :error -> {:halt, {:error, {:missing_root, root}}}
      end
    end)
    |> case do
      :ok -> {:ok, roots}
      error -> error
    end
  end

  # G1. A candidate that asserts its own lifecycle is refused rather than
  # having the assertion quietly ignored, so the failure is visible.
  defp reject_self_declaration(payload) when is_map(payload) do
    claimed? =
      payload
      |> Map.values()
      |> Enum.any?(fn value ->
        is_binary(value) and String.downcase(value) in @lifecycle_claims
      end)

    if claimed?, do: {:error, :self_adoption}, else: :ok
  end

  defp reject_self_declaration(_payload), do: {:error, :invalid_adoption_input}

  defp transition_allowed(from, to) do
    cond do
      from not in @states -> {:error, :invalid_lifecycle_state}
      to in Map.get(@transitions, from, []) -> :ok
      true -> {:error, :invalid_lifecycle_transition}
    end
  end

  defp fresh_epoch(roots, grant_epoch_id) do
    if id_string(roots.grant_epoch) == grant_epoch_id,
      do: :ok,
      else: {:error, :stale_grant}
  end

  defp same_spec(%ContentID{digest: a}, %ContentID{digest: b}) when a == b, do: :ok
  defp same_spec(_a, _b), do: {:error, :substituted_artifact}

  # The path must have been built under the same roots being adopted under.
  # Without this, a path minted under different roots could be replayed to
  # adopt bytes it never covered.
  defp bound_authorization(%Constitution.Path{root_set: root_set}, roots) do
    same_roots(root_set.roots, roots)
  end

  defp stringify(roots) do
    Map.new(roots, fn
      {k, %ContentID{} = id} -> {to_string(k), id_string(id)}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp same_roots(a, b) do
    if stringify(a) == stringify(b), do: :ok, else: {:error, :substituted_artifact}
  end

  defp seal(spec_id, roots, authorization, decision_ref, grant_epoch_id) do
    alias SpruceGoose.Kernel.Canonical

    attrs = %{
      spec_id: spec_id,
      roots: roots,
      authorization_id: authorization.id,
      decision_ref: decision_ref,
      grant_epoch_id: grant_epoch_id,
      state: :adopted
    }

    with {:ok, bytes} <- Canonical.encode(canonical_form(attrs)),
         {:ok, id} <- ContentID.derive(:sha256, bytes) do
      {:ok, struct!(Adoption, Map.put(attrs, :id, id))}
    end
  end

  defp canonical_form(attrs) do
    %{
      "authorization_id" => id_string(attrs.authorization_id),
      "decision_ref" => attrs.decision_ref,
      "grant_epoch_id" => attrs.grant_epoch_id,
      "roots" => stringify(attrs.roots),
      "spec_id" => id_string(attrs.spec_id),
      "state" => to_string(attrs.state)
    }
  end

  # ContentID carries no string formatter of its own, so identity is rendered
  # here as algorithm-qualified hex. Qualifying with the algorithm keeps two
  # digests from different algorithms from ever colliding in canonical bytes.
  defp id_string(%ContentID{algorithm: algorithm, digest: digest}) do
    "#{algorithm}:#{digest}"
  end

  # P2: the idempotency key is the spec identity. Re-adopting identical bytes
  # under an identical decision reproduces identical canonical content and
  # succeeds; changed content under the same key refuses at the ledger.
  defp certify(%Adoption{} = adoption) do
    CertifiedEvent.new(%{
      stream: @stream,
      event_type: @event_type,
      idempotency_key: id_string(adoption.spec_id),
      payload: canonical_form(adoption),
      roots: stringify(adoption.roots)
    })
  end
end
