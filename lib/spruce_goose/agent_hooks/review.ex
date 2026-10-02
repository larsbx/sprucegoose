defmodule SpruceGoose.AgentHooks.Review do
  @moduledoc "Read-only CLI views; reviewing a result never applies its recommendation."
  require Ash.Query
  alias SpruceGoose.AgentHooks.{Run, TriageResult}
  alias SpruceGoose.Authz

  def list do
    with {:ok, runs} <-
           Authz.read(Run |> Ash.Query.sort(inserted_at: :desc, id: :desc) |> Ash.Query.limit(50)),
         {:ok, results} <-
           Authz.read(TriageResult |> Ash.Query.filter(run_id in ^Enum.map(runs, & &1.id))) do
      by_run = Map.new(results, &{&1.run_id, &1})

      {:ok,
       %{
         limit: 50,
         runs:
           Enum.map(runs, fn run ->
             %{
               run_id: run.id,
               capture_id: run.context["inbox"]["capture_id"],
               event_key: run.event_key,
               hook_version: run.hook_version,
               outcome:
                 case by_run[run.id] do
                   nil -> :pending
                   result -> result.outcome
                 end,
               inserted_at: run.inserted_at
             }
           end)
       }}
    end
  end

  def show(id) do
    with {:ok, ^id} <- Ecto.UUID.cast(id),
         {:ok, run} <- Authz.read_one(Run, id: id),
         {:ok, results} <- Authz.read(TriageResult |> Ash.Query.filter_input(run_id: run.id)) do
      {:ok,
       %{
         run:
           Map.take(run, [
             :id,
             :event_key,
             :hook_id,
             :hook_version,
             :actor_id,
             :config_digest,
             :charter_digest,
             :context_digest,
             :context,
             :inserted_at
           ]),
         result:
           case results do
             [] ->
               nil

             [result] ->
               Map.take(result, [
                 :id,
                 :run_id,
                 :actor_id,
                 :outcome,
                 :proposal,
                 :proposal_digest,
                 :context_digest,
                 :reason,
                 :inserted_at
               ])
           end
       }}
    else
      :error -> {:error, "run ID must be a canonical UUID"}
      {:ok, _} -> {:error, "run ID must be a canonical UUID"}
      error -> error
    end
  end
end
