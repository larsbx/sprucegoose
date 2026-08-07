defmodule SpruceGoose.Actors.Refusal do
  @moduledoc """
  Turn an `Ash.Error.Forbidden` into a sentence that says what grant is missing.

  Ash's own message is a bread-crumb and a stack frame. That is fine for a
  library, and useless as the answer an agent gets back when it is refused — the
  whole value of a scoped permission system is that the refusal tells you which
  grant to ask for. So the policy error is unpacked into the actor, the action
  it attempted, the scope that action fell under, and what the actor actually
  holds.
  """

  alias SpruceGoose.Actors.Scope

  def message(%Ash.Error.Forbidden{errors: errors}, actor) do
    case Enum.find(errors, &match?(%Ash.Error.Forbidden.Policy{}, &1)) do
      %Ash.Error.Forbidden.Policy{resource: resource, action: action} ->
        describe(actor, resource, action)

      _ ->
        describe(actor, nil, nil)
    end
  end

  def message(error, _actor) when is_exception(error), do: Exception.message(error)
  def message(error, _actor), do: inspect(error)

  defp describe(actor, resource, action) do
    attempt =
      case {resource, action} do
        {nil, _} -> "that action"
        {resource, nil} -> "#{short(resource)}"
        {resource, action} -> "#{short(resource)}.#{action_name(action)}"
      end

    "#{name(actor)} is not authorized to #{attempt}. #{holdings(actor)}"
  end

  defp holdings(actor) do
    case grants(actor) do
      [] ->
        "It holds no grants at all — ask an admin for one with " <>
          "`sprucegoose grant add #{bare_name(actor)} --role ROLE --scope SCOPE`."

      held ->
        "It holds: " <>
          Enum.map_join(held, ", ", &"#{&1.role} on #{&1.scope}") <>
          ". Ask an admin to widen that if this is work it should be doing."
    end
  end

  defp grants(actor) when is_struct(actor), do: Scope.summary(actor)
  defp grants(_actor), do: []

  defp name(%{name: name}), do: "actor #{name}"
  defp name(_actor), do: "the caller"

  # The bare name goes into a command the reader is meant to copy; "actor lars"
  # would paste back as a command that does not run.
  defp bare_name(%{name: name}), do: name
  defp bare_name(_actor), do: "NAME"

  defp action_name(%{name: name}), do: name
  defp action_name(name), do: name

  defp short(resource) do
    resource |> Module.split() |> List.last()
  end
end
