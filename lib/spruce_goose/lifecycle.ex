defmodule SpruceGoose.Lifecycle do
  @moduledoc """
  A versioned, fail-closed, finite lifecycle contract, declared once and
  shared by every state machine in SpruceGoose.

      use SpruceGoose.Lifecycle,
        version: 1,
        initial: :queued,
        transitions: [queued: [:building, :cancelled], building: [...], ...],
        terminal: [:ready, :failed, :rolled_back, :cancelled]

  `transitions` is an ordered keyword list: its keys are the state set Σ, in
  the order persisted enums and listings present them, and its values are
  the successor relation δ ⊆ Σ × Σ. `terminal` defaults to the sink states
  (those with no successors); declare it explicitly when "finished" is wider
  than "absorbing", as it is for deployments.

  The declaration is verified when the module compiles (`verify!/4`): every
  successor, the initial state, and every terminal state must be declared
  states, no state may be declared twice, and every sink state must be
  terminal. Reachability is exposed (`reachable/1`) so tests can decide the
  remaining properties exhaustively rather than sample them.

  The relation is only the *shape* of a lifecycle. Preconditions that depend
  on data (evidence, reasons, predecessors, gates) belong to the resource
  action that performs the transition.
  """

  @type state :: atom()
  @type transitions :: %{state() => [state()]}

  @callback version() :: pos_integer()
  @callback initial() :: state()
  @callback states() :: [state()]
  @callback transitions() :: transitions()
  @callback terminal_states() :: [state()]
  @callback terminal?(state()) :: boolean()
  @callback successors(state()) :: [state()]
  @callback transition(state(), state()) :: {:ok, state()} | {:error, :invalid_transition}
  @callback allowed?(state(), state()) :: boolean()
  @callback allowed_from(state()) :: [state()]
  @callback parse(term()) :: {:ok, state()} | {:error, :unknown_state}
  @callback reachable(state()) :: [state()]
  @callback sql_membership(String.t()) :: String.t()

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour SpruceGoose.Lifecycle

      @version Keyword.fetch!(opts, :version)
      @initial Keyword.fetch!(opts, :initial)
      @table Keyword.fetch!(opts, :transitions)
      @states Keyword.keys(@table)
      @transitions Map.new(@table)
      @terminal_states Keyword.get_lazy(opts, :terminal, fn ->
                         for {state, []} <- @table, do: state
                       end)

      :ok = SpruceGoose.Lifecycle.verify!(__MODULE__, @initial, @table, @terminal_states)

      @impl true
      def version, do: @version

      @impl true
      def initial, do: @initial

      @impl true
      def states, do: @states

      @impl true
      def transitions, do: @transitions

      @impl true
      def terminal_states, do: @terminal_states

      @impl true
      def terminal?(state), do: state in @terminal_states

      @doc "Legal successors of a state. Unknown states have none."
      @impl true
      def successors(state), do: Map.get(@transitions, state, [])

      @doc "The legal successor, or a refusal."
      @impl true
      def transition(from, to),
        do: if(to in successors(from), do: {:ok, to}, else: {:error, :invalid_transition})

      @impl true
      def allowed?(from, to), do: to in successors(from)

      @impl true
      def allowed_from(state), do: successors(state)

      @doc "Parse a persisted state name back into the closed set."
      @impl true
      def parse(name) when is_binary(name) do
        Enum.find_value(
          @states,
          {:error, :unknown_state},
          &if(Atom.to_string(&1) == name, do: {:ok, &1})
        )
      end

      def parse(state) when state in @states, do: {:ok, state}
      def parse(_), do: {:error, :unknown_state}

      @doc "Every state reachable from `from` (inclusive), by default from the initial state."
      @impl true
      def reachable(from \\ @initial), do: SpruceGoose.Lifecycle.closure(@transitions, from)

      @doc "A SQL predicate holding when `column` is one of the declared states."
      @impl true
      def sql_membership(column), do: SpruceGoose.Lifecycle.sql_membership(column, @states)
    end
  end

  @doc """
  Check a declaration's static invariants, raising `ArgumentError` naming the
  module and the offending state when one fails.
  """
  @spec verify!(module(), state(), keyword([state()]), [state()]) :: :ok
  def verify!(module, initial, table, terminal) do
    states = Keyword.keys(table)
    declared = MapSet.new(states)
    fail = &raise(ArgumentError, "#{inspect(module)}: #{&1}")

    states
    |> Enum.frequencies()
    |> Enum.find(fn {_state, count} -> count > 1 end)
    |> case do
      {state, _} -> fail.("state #{inspect(state)} is declared twice")
      nil -> :ok
    end

    initial in declared || fail.("initial state #{inspect(initial)} is not declared")

    for state <- terminal,
        state not in declared,
        do: fail.("terminal state #{inspect(state)} is not declared")

    for {from, successors} <- table,
        to <- successors,
        to not in declared,
        do: fail.("#{from} transitions to undeclared state #{inspect(to)}")

    for {state, []} <- table,
        state not in terminal,
        do: fail.("sink state #{inspect(state)} is not terminal")

    :ok
  end

  @doc "Render Σ as a SQL `IN` predicate over `column`, for check constraints."
  @spec sql_membership(String.t(), [state()]) :: String.t()
  def sql_membership(column, states),
    do: "#{column} IN (#{Enum.map_join(states, ",", &"'#{&1}'")})"

  @doc "Render a lifecycle as the Markdown table `docs/lifecycles.md` carries."
  @spec to_markdown(module()) :: String.t()
  def to_markdown(machine) do
    rows =
      Enum.map_join(machine.states(), "\n", fn state ->
        successors =
          case machine.successors(state) do
            [] -> "—"
            next -> Enum.map_join(next, ", ", &"`#{&1}`")
          end

        "| `#{state}` | #{successors} |"
      end)

    terminal = Enum.map_join(machine.terminal_states(), ", ", &"`#{&1}`")

    """
    `#{inspect(machine)}`, version #{machine.version()}. Initial state `#{machine.initial()}`; terminal states #{terminal}.

    | from | to |
    | --- | --- |
    #{rows}
    """
  end

  @doc "Reflexive-transitive closure of the relation from one state, in first-visit order."
  @spec closure(transitions(), state()) :: [state()]
  def closure(transitions, from), do: walk(transitions, [from], MapSet.new([from]), [])

  defp walk(_transitions, [], _seen, acc), do: Enum.reverse(acc)

  defp walk(transitions, [state | queue], seen, acc) do
    fresh = transitions |> Map.get(state, []) |> Enum.reject(&MapSet.member?(seen, &1))
    walk(transitions, queue ++ fresh, MapSet.union(seen, MapSet.new(fresh)), [state | acc])
  end
end
