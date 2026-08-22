defmodule SpruceGoose.Authz do
  @moduledoc """
  The only way the CLI reaches Ash.

  The Workflows domain runs `authorize :when_requested`, so a bare `Ash.update/3`
  is *unauthorized* — silently, and with no error to notice. That is the wrong
  failure mode for the one surface where every write happens, so every CLI call
  goes through here, where `actor:` and `authorize?: true` are not optional.

  ## Why the actor is request-scoped rather than an argument

  Threading an actor through sixty-odd command clauses and twenty private
  helpers gives twenty more chances to drop it, and dropping it is silent. So
  `run/2` establishes the actor once for the request with `with_actor/2`, and
  `actor!/0` **raises** if a call is made outside that scope. An implicit
  dependency that cannot fail quietly beats an explicit one that can.

  The scope is the calling process. `SpruceGoose.CLI.SocketPlug` runs each
  request in its own supervised task, so requests cannot see each other's actor.

  `test/authz_lint_test.exs` fails the build if a CLI module calls `Ash.create`,
  `Ash.update`, `Ash.destroy` or `Ash.read` directly. That test is what makes
  this module mandatory rather than merely available.

  `:when_requested` rather than Ash's `:by_default` is a deliberate trade: the
  suite has 142 direct `Ash.*` call sites that legitimately act as the system,
  and rewriting all of them to opt out would be a larger, noisier change than
  the guarantee is worth. The lint test recovers the guarantee where it matters.
  """

  require Ash.Query

  @key :spruce_goose_actor

  @doc "Run `fun` with `actor` as the acting party for every Authz call inside it."
  def with_actor(actor, fun) do
    previous = Process.put(@key, actor)

    try do
      fun.()
    after
      if is_nil(previous), do: Process.delete(@key), else: Process.put(@key, previous)
    end
  end

  @doc "The acting actor. Raises rather than defaulting: no actor is not a permission."
  def actor! do
    case Process.get(@key) do
      nil ->
        raise "SpruceGoose.Authz called with no actor in scope; " <>
                "every CLI request must run inside Authz.with_actor/2"

      actor ->
        actor
    end
  end

  def actor, do: Process.get(@key)

  @doc "Read one record by filter, refusing rather than returning nil."
  def read_one(resource, filter) do
    resource
    |> Ash.Query.filter_input(filter)
    |> Ash.read_one(opts())
    |> case do
      {:ok, nil} -> {:error, "not found"}
      result -> result
    end
  end

  def read(query_or_resource), do: Ash.read(query_or_resource, opts())
  def count(query), do: Ash.count(query, opts())

  def create(resource, input, extra \\ []) do
    notify(Ash.create(resource, input, notification_opts(extra)))
  end

  def create_with_notifications(resource, input, extra \\ []) do
    Ash.create(resource, input, opts(Keyword.put(extra, :return_notifications?, true)))
  end

  def update(record, input, extra \\ []) do
    notify(Ash.update(record, input, notification_opts(extra)))
  end

  def update_changeset(changeset, extra \\ []) do
    notify(Ash.update(changeset, notification_opts(extra)))
  end

  def destroy(record) do
    destroy_opts =
      if SpruceGoose.Kernel.ShadowEvents.collecting_notifications?(),
        do: opts(return_destroyed?: true, return_notifications?: true),
        else: opts()

    case Ash.destroy(record, destroy_opts) do
      :ok ->
        :ok

      {:ok, _destroyed} ->
        :ok

      {:ok, _destroyed, notifications} ->
        SpruceGoose.Kernel.ShadowEvents.collect_notifications(notifications)

      error ->
        error
    end
  end

  defp notification_opts(extra) do
    if SpruceGoose.Kernel.ShadowEvents.collecting_notifications?(),
      do: opts(Keyword.put(extra, :return_notifications?, true)),
      else: opts(extra)
  end

  defp notify({:ok, record, notifications}) do
    if SpruceGoose.Kernel.ShadowEvents.collecting_notifications?() do
      :ok = SpruceGoose.Kernel.ShadowEvents.collect_notifications(notifications)
      {:ok, record}
    else
      {:ok, record, notifications}
    end
  end

  defp notify(result), do: result

  defp opts(extra \\ []), do: Keyword.merge(extra, actor: actor!(), authorize?: true)
end
