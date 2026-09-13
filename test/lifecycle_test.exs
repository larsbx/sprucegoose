defmodule SpruceGoose.LifecycleTest do
  @moduledoc """
  One contract, two machines.

  Every property here is decided, not sampled: the relations are finite, so
  the tests enumerate the whole state set and the whole relation.
  """
  use ExUnit.Case, async: true

  alias SpruceGoose.Deployment
  alias SpruceGoose.Workflows
  alias SpruceGoose.Workflows.TaskState

  @machines [Workflows.Lifecycle, Deployment.Lifecycle]

  for machine <- @machines do
    describe inspect(machine) do
      @machine machine

      test "is a versioned SpruceGoose.Lifecycle" do
        assert SpruceGoose.Lifecycle in behaviours(@machine)
        assert is_integer(@machine.version()) and @machine.version() >= 1
      end

      test "the relation is closed over the declared state set" do
        states = MapSet.new(@machine.states())

        assert @machine.initial() in states
        assert MapSet.subset?(MapSet.new(@machine.terminal_states()), states)

        for {from, successors} <- @machine.transitions() do
          assert from in states
          assert MapSet.subset?(MapSet.new(successors), states), "#{from} leaves the state set"
        end

        assert Enum.sort(Map.keys(@machine.transitions())) == Enum.sort(@machine.states())
      end

      test "every sink state is terminal" do
        for state <- @machine.states(), @machine.successors(state) == [] do
          assert @machine.terminal?(state), "#{state} has no successors but is not terminal"
        end
      end

      test "every state is reachable from the initial state" do
        assert Enum.sort(@machine.reachable()) == Enum.sort(@machine.states())
      end

      test "every state can reach a terminal state" do
        for state <- @machine.states() do
          assert Enum.any?(@machine.reachable(state), &@machine.terminal?/1),
                 "#{state} cannot reach a terminal state"
        end
      end

      test "transition/2, allowed?/2 and allowed_from/1 are the same relation" do
        for from <- @machine.states(), to <- @machine.states() do
          expected =
            if to in @machine.successors(from),
              do: {:ok, to},
              else: {:error, :invalid_transition}

          assert @machine.transition(from, to) == expected
          assert @machine.allowed?(from, to) == match?({:ok, _}, expected)
        end

        for state <- @machine.states() do
          assert @machine.allowed_from(state) == @machine.successors(state)
        end
      end

      test "unknown states have no successors" do
        assert @machine.successors(:sudo) == []
        assert @machine.transition(:sudo, @machine.initial()) == {:error, :invalid_transition}
        assert @machine.transition(@machine.initial(), :sudo) == {:error, :invalid_transition}
        refute @machine.allowed?(:sudo, :sudo)
      end

      test "parse/1 round-trips persisted names and refuses everything else" do
        for state <- @machine.states() do
          assert {:ok, ^state} = @machine.parse(Atom.to_string(state))
          assert {:ok, ^state} = @machine.parse(state)
        end

        assert {:error, :unknown_state} = @machine.parse("sudo")
        assert {:error, :unknown_state} = @machine.parse(:sudo)
        assert {:error, :unknown_state} = @machine.parse(nil)
      end
    end
  end

  describe "task lifecycle" do
    test "is exactly the relation the Task resource enforces" do
      assert Workflows.Lifecycle.version() == 1
      assert Workflows.Lifecycle.initial() == :inbox

      assert Workflows.Lifecycle.transitions() == %{
               inbox: [:proposed, :cancelled],
               proposed: [:queued, :cancelled],
               queued: [:ready, :blocked, :cancelled],
               ready: [:in_progress, :blocked, :cancelled],
               in_progress: [:waiting, :blocked, :completed, :failed, :cancelled],
               waiting: [:ready, :in_progress, :blocked, :cancelled],
               blocked: [:ready, :cancelled],
               failed: [:queued, :cancelled],
               completed: [],
               cancelled: []
             }

      assert Enum.sort(Workflows.Lifecycle.terminal_states()) == [:cancelled, :completed]
    end

    test "the persisted enum is the lifecycle's state set, in declaration order" do
      assert TaskState.values() == Workflows.Lifecycle.states()

      assert Workflows.Lifecycle.states() ==
               ~w(inbox proposed queued ready in_progress waiting blocked completed failed cancelled)a
    end

    test "failed is recoverable, completed and cancelled are absorbing" do
      refute Workflows.Lifecycle.terminal?(:failed)
      assert {:ok, :queued} = Workflows.Lifecycle.transition(:failed, :queued)

      for terminal <- Workflows.Lifecycle.terminal_states(), to <- Workflows.Lifecycle.states() do
        assert {:error, :invalid_transition} = Workflows.Lifecycle.transition(terminal, to)
      end
    end
  end

  describe "deployment lifecycle" do
    test "carries the native control plane's relation unchanged" do
      assert Deployment.Lifecycle.version() == 1
      assert Deployment.Lifecycle.initial() == :queued

      assert Deployment.Lifecycle.transitions() == %{
               queued: [:building, :cancelled],
               building: [:staged, :failed, :cancelled],
               staged: [:deploying, :cancelled],
               deploying: [:verifying, :failed, :rolling_back],
               verifying: [:ready, :failed, :rolling_back],
               ready: [:rolling_back],
               failed: [:rolling_back],
               rolling_back: [:rolled_back, :failed],
               rolled_back: [],
               cancelled: []
             }

      assert Enum.sort(Deployment.Lifecycle.terminal_states()) ==
               [:cancelled, :failed, :ready, :rolled_back]
    end

    test "terminal is finished, not absorbing: ready and failed may still roll back" do
      assert Deployment.Lifecycle.terminal?(:ready)
      assert {:ok, :rolling_back} = Deployment.Lifecycle.transition(:ready, :rolling_back)
    end
  end

  describe "docs/lifecycles.md" do
    @doc_path Path.expand("../docs/lifecycles.md", __DIR__)

    for machine <- @machines do
      @machine machine
      test "carries the rendered #{inspect(machine)} table" do
        marker = "<!-- lifecycle:#{inspect(@machine)} -->"
        doc = File.read!(@doc_path)
        assert [_, rest] = String.split(doc, marker, parts: 2), "#{marker} missing"
        assert [block, _] = String.split(rest, "<!-- /lifecycle -->", parts: 2)

        assert String.trim(block) == String.trim(SpruceGoose.Lifecycle.to_markdown(@machine)),
               "docs/lifecycles.md is stale for #{inspect(@machine)}; regenerate it"
      end
    end
  end

  describe "declaration verification" do
    test "refuses a successor outside the state set" do
      assert_raise ArgumentError, ~r/undeclared state.*:gone/, fn ->
        SpruceGoose.Lifecycle.verify!(Bad, :a, [a: [:gone]], [])
      end
    end

    test "refuses an initial state outside the state set" do
      assert_raise ArgumentError, ~r/initial state :z/, fn ->
        SpruceGoose.Lifecycle.verify!(Bad, :z, [a: []], [:a])
      end
    end

    test "refuses a terminal state outside the state set" do
      assert_raise ArgumentError, ~r/terminal state :z/, fn ->
        SpruceGoose.Lifecycle.verify!(Bad, :a, [a: []], [:a, :z])
      end
    end

    test "refuses a sink state that is not terminal" do
      assert_raise ArgumentError, ~r/sink state :b/, fn ->
        SpruceGoose.Lifecycle.verify!(Bad, :a, [a: [:b], b: []], [:a])
      end
    end

    test "refuses a duplicated state" do
      assert_raise ArgumentError, ~r/declared twice/, fn ->
        SpruceGoose.Lifecycle.verify!(Bad, :a, [a: [], a: []], [:a])
      end
    end

    test "accepts a well-formed declaration" do
      assert :ok = SpruceGoose.Lifecycle.verify!(Good, :a, [a: [:b], b: []], [:b])
    end
  end

  defp behaviours(module),
    do: module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
end
