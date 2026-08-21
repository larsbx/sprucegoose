defmodule SpruceGoose.Actors.Resolver do
  @moduledoc """
  How a request becomes an actor.

  Deliberately a behaviour with a single adapter today, for the same reason
  `SpruceGoose.Identity` is: the boundary here is weak, it is known to be weak,
  and the weakness should be replaceable without touching a single policy.

  ## The boundary

  Every agent on this host — OpenClaw, Pi, Claude Code, Codex — runs as the same
  unix user. `SO_PEERCRED` on the CLI socket returns the same uid for all of
  them. So `--as openclaw` is a *declaration*, not a credential, and the
  `Declared` adapter is honest about that: it looks the name up and refuses
  unknown or disabled actors, but it cannot tell a caller that lies.

  This is the same class of control as `vault-write-authorization.py`: it makes
  ungoverned and out-of-scope action fail loudly by default and binds every
  mutation to a named actor. It withholds no secret, and a determined local
  process bypasses it by writing rows directly.

  ## Replacing it

  Two adapters would move the boundary for real, and neither changes a policy:

  - a token-bound adapter, resolving a per-actor secret through the
    `AshAuthentication` token store already in this app;
  - a peer-credential adapter, once agents run as distinct unix users, reading
    the uid the kernel attaches to the socket — which cannot be forged.
  """

  alias SpruceGoose.Actors.Actor

  @doc "Resolve a caller-supplied name to an active actor."
  @callback resolve(name :: String.t() | nil) :: {:ok, Actor.t()} | {:error, String.t()}

  def adapter do
    Application.get_env(:spruce_goose, :actor_resolver, SpruceGoose.Actors.Resolver.Declared)
  end

  def resolve(name), do: adapter().resolve(name)
end
