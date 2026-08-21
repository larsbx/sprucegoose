defmodule SpruceGoose.Checks.HasRole do
  @moduledoc """
  Does the acting actor hold the required role over the scope of the thing being
  changed?

  Used for mutations only. Reads go through `SpruceGoose.Checks.Readable`, which
  filters instead of refusing so a project-scoped reader's `list` commands
  return their slice rather than an error.

  A scope that cannot be resolved is a refusal, never a default: an unknown
  scope is not one anybody was granted.
  """

  use Ash.Policy.SimpleCheck

  alias SpruceGoose.Actors.{Actor, Scope}

  @impl true
  def describe(opts), do: "actor holds #{opts[:role]} over the subject's scope"

  @impl true
  def match?(%Actor{} = actor, context, opts) do
    with true <- Actor.active?(actor),
         {:ok, subject} <- subject(context),
         {:ok, scope} <- Scope.of(subject) do
      Scope.holds?(actor, opts[:role], scope)
    else
      _ -> false
    end
  end

  def match?(_actor, _context, _opts), do: false

  defp subject(%{changeset: %Ash.Changeset{} = changeset}), do: {:ok, changeset}
  defp subject(%{subject: %Ash.Changeset{} = changeset}), do: {:ok, changeset}
  defp subject(_context), do: :error

  @doc "Constructors so policy blocks read as prose."
  def operator, do: {__MODULE__, role: :operator}
  def derivation_executor, do: {__MODULE__, role: :derivation_executor}
  def artifact_verifier, do: {__MODULE__, role: :artifact_verifier}
  def proposer, do: {__MODULE__, role: :proposer}
  def approver, do: {__MODULE__, role: :approver}
  def author, do: {__MODULE__, role: :author}
end
