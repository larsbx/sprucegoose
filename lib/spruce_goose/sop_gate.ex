defmodule SpruceGoose.SopGate do
  @moduledoc """
  The Systemwide SOP acknowledgment gate.

  A task records *which SOP it was admitted under*: the document's declared
  version, and the SHA-256 of the exact bytes read. The version decides whether
  an acknowledgment is still good; the digest is the evidence of what was
  actually read.

  ## Why a version at all

  Before this, the digest alone governed, so **any** byte change invalidated
  every acknowledgment on the fleet. Fixing one typo forced every in-progress
  task to re-acknowledge, which made the document that governs everything else
  the most expensive one to correct.

  ## The rule

  | SOP declares a version | task holds one | outcome |
  |---|---|---|
  | no | no | digest must match exactly — the original behaviour |
  | no | yes | refused: the SOP lost a version it had |
  | yes | no | grandfathered — valid while the SOP is still at `grandfather_version/0` |
  | yes | yes | valid while `MAJOR.MINOR` is unchanged |

  A rollback to a *lower* version is refused in every case. An SOP going
  backwards must not silently re-validate acknowledgments of a newer one.

  ## The honest trade

  A patch bump now carries authority: it asserts "no rule changed here", and
  nothing but discipline enforces that. The digest still records the bytes each
  task actually read, so a dishonest patch bump is discoverable after the fact —
  it is not prevented. That is the price of being able to fix a typo without
  re-acknowledging the fleet.

  `scripts/vault-write-authorization.py` in the openclaw-system vault
  re-implements this same rule for the git write gate. The two must agree; the
  table above is the shared contract.
  """

  @id "systemwide-sop"

  # Deliberately not a YAML parser. This block is a governed control surface,
  # not arbitrary metadata, so it accepts exactly two keys in exactly one shape
  # and refuses anything else rather than interpreting it generously.
  @frontmatter_keys ~w(sop_id version)

  def id, do: @id
  def path, do: Application.fetch_env!(:spruce_goose, :systemwide_sop_path)

  @adoption "constitution/adopted.json"
  @adoption_path Path.expand("../../priv/#{@adoption}", __DIR__)
  @external_resource @adoption_path
  @adopted_bytes File.read!(@adoption_path)

  @doc """
  The digest this repository has adopted for the Systemwide SOP.

  The SOP's bytes live in the openclaw-system vault rather than here, because
  `scripts/vault-write-authorization.py` enforces the same rule against the same
  document. That is a deliberate split, but it left the `norm` constitutional
  root as the digest of a file nobody outside one host could hash — so the test
  that validated the root set could only ever run on that host.

  `priv/constitution/adopted.json` closes that: the adopted digest is reviewable
  from this repository alone and changes only through a reviewed commit.
  """
  def adopted_digest do
    case Jason.decode(@adopted_bytes) do
      {:ok,
       %{"artifacts" => %{@id => %{"digest" => "sha256:" <> _ = digest, "custody" => custody}}}}
      when custody != "absent" ->
        {:ok, digest}

      _ ->
        {:error, "the adopted-artifact record does not declare an adopted #{@id} digest"}
    end
  end

  @doc """
  Check the deployed SOP against the adopted digest.

  Stronger than the test it replaces: that ran once, at CI time, on whichever
  machine happened to hold the file. This runs on the machine actually serving
  requests, against the bytes it will actually gate on.

  Returns `:ok` when they agree, and names both digests when they do not.
  """
  def verify_adoption do
    with {:ok, adopted} <- adopted_digest(),
         {:ok, body} <- read(path()) do
      deployed = "sha256:" <> digest(body)

      if deployed == adopted do
        :ok
      else
        {:error,
         "the deployed Systemwide SOP at #{path()} digests to #{deployed}, but this " <>
           "release adopted #{adopted}. Either the deployment is serving an unreviewed " <>
           "SOP, or priv/constitution/adopted.json is behind a reviewed SOP change"}
      end
    end
  end

  @doc """
  The version a *version-less* acknowledgment is treated as having read.

  Acknowledgments predating versioning carry no version. Treating them as having
  read the baseline is what lets the SOP declare a version for the first time
  without invalidating every task in flight — the alternative would make
  introducing versioning the exact flag day versioning exists to prevent.
  """
  def grandfather_version,
    do: Application.get_env(:spruce_goose, :sop_grandfather_version, "1.0.0")

  def acknowledge(candidate_path) do
    with :ok <- require_configured_path(candidate_path),
         {:ok, body} <- read(candidate_path),
         {:ok, version} <- declared_version(body) do
      {:ok,
       %{
         sop_gate_required: true,
         sop_id: @id,
         sop_path: candidate_path,
         sop_digest: digest(body),
         sop_version: version,
         sop_acknowledged_at: DateTime.utc_now()
       }}
    end
  end

  def verify(%{sop_gate_required: false}), do: :ok

  def verify(%{sop_id: @id, sop_path: acknowledged_path} = task) do
    configured = path()

    with :ok <- require_same_path(acknowledged_path, configured),
         {:ok, body} <- read(configured),
         {:ok, current} <- declared_version(body) do
      compare(Map.get(task, :sop_version), current, Map.get(task, :sop_digest), body)
    end
  end

  def verify(_task), do: {:error, "task has no trusted Systemwide SOP acknowledgment"}

  # -- the rule table --------------------------------------------------------

  # Unversioned SOP, unversioned acknowledgment: exactly the original behaviour.
  # This is the branch every task takes until the document declares a version,
  # which is what makes deploying this change ahead of that edit a no-op.
  defp compare(nil, nil, acknowledged_digest, body) do
    if digest(body) == acknowledged_digest,
      do: :ok,
      else: {:error, "Systemwide SOP acknowledgment is stale; run task acknowledge-sop"}
  end

  defp compare(acknowledged, nil, _digest, _body) when is_binary(acknowledged) do
    {:error,
     "the Systemwide SOP no longer declares a version, but this task acknowledged " <>
       "#{acknowledged}. Restore the version block rather than removing the gate"}
  end

  defp compare(nil, current, _digest, _body) do
    baseline = grandfather_version()

    if same_line?(baseline, current) do
      :ok
    else
      {:error,
       "this task predates SOP versioning, so it is treated as having read " <>
         "#{baseline}; the SOP is now #{current}. Run task acknowledge-sop"}
    end
  end

  defp compare(acknowledged, current, _digest, _body) do
    cond do
      rolled_back?(acknowledged, current) ->
        {:error,
         "the Systemwide SOP is #{current}, older than the #{acknowledged} this task " <>
           "acknowledged. An SOP rollback does not re-validate acknowledgments"}

      same_line?(acknowledged, current) ->
        :ok

      true ->
        {:error,
         "Systemwide SOP acknowledgment is stale: this task acknowledged #{acknowledged}, " <>
           "the SOP is now #{current}. Run task acknowledge-sop"}
    end
  end

  # A patch bump asserts that no rule changed, so only MAJOR.MINOR is compared.
  defp same_line?(a, b) do
    with {:ok, left} <- Version.parse(a), {:ok, right} <- Version.parse(b) do
      left.major == right.major and left.minor == right.minor
    else
      _ -> false
    end
  end

  defp rolled_back?(acknowledged, current) do
    with {:ok, left} <- Version.parse(acknowledged), {:ok, right} <- Version.parse(current) do
      Version.compare(right, left) == :lt
    else
      _ -> false
    end
  end

  # -- frontmatter -----------------------------------------------------------

  @doc """
  The version the document declares, or `nil` if it declares no frontmatter.

  Absent frontmatter is legitimate — that is the pre-versioning state. Present
  but unparseable is not: a governed document whose control block cannot be read
  fails closed.
  """
  def declared_version("---\n" <> rest) do
    case String.split(rest, ~r/^---\s*$/m, parts: 2) do
      [block, _body] -> parse_frontmatter(block)
      _ -> {:error, "the Systemwide SOP opens a frontmatter block it never closes"}
    end
  end

  def declared_version(_body), do: {:ok, nil}

  defp parse_frontmatter(block) do
    block
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          key = String.trim(key)
          value = value |> String.trim() |> String.trim(~s("))

          if key in @frontmatter_keys do
            {:cont, {:ok, Map.put(acc, key, value)}}
          else
            {:halt,
             {:error,
              "Systemwide SOP frontmatter has an unsupported key #{inspect(key)}; " <>
                "only #{Enum.join(@frontmatter_keys, " and ")} are allowed"}}
          end

        _ ->
          {:halt,
           {:error, "Systemwide SOP frontmatter line is not key: value — #{inspect(line)}"}}
      end
    end)
    |> case do
      {:ok, fields} -> validate_frontmatter(fields)
      error -> error
    end
  end

  defp validate_frontmatter(fields) do
    version = Map.get(fields, "version")
    declared_id = Map.get(fields, "sop_id")

    cond do
      is_nil(version) ->
        {:error, "Systemwide SOP frontmatter declares no version"}

      match?(:error, Version.parse(version)) ->
        {:error, "Systemwide SOP version #{inspect(version)} is not semantic versioning"}

      # The id was hardcoded and assumed before; declaring it makes the document
      # say what it is, and a mismatch means the configured path points at some
      # other document entirely.
      not is_nil(declared_id) and declared_id != @id ->
        {:error,
         "Systemwide SOP declares sop_id #{inspect(declared_id)}; expected #{inspect(@id)}"}

      true ->
        {:ok, version}
    end
  end

  # -- plumbing --------------------------------------------------------------

  defp require_configured_path(candidate) do
    if candidate == path(), do: :ok, else: {:error, "SOP path must be #{path()}"}
  end

  defp require_same_path(acknowledged, configured) do
    if acknowledged == configured,
      do: :ok,
      else: {:error, "Systemwide SOP acknowledgment uses the prior configured path"}
  end

  defp read(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, "cannot read configured Systemwide SOP: #{reason}"}
    end
  end

  defp digest(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
