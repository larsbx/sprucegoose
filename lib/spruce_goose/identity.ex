defmodule SpruceGoose.Identity do
  @moduledoc """
  The peer identity and origin sequence contract (docs/identifier-model.md).

  This is deliberately a behaviour with a single local adapter today. The
  identifier model consumes *this contract*, never the adapter, so when
  `coop_substrate` is assimilated its canonical log becomes a new adapter
  module rather than a rewrite of every derivation site.

  `coop_substrate`'s log already provides the same primitives under different
  names: `global_seq` / `stream_seq` for the counter, Ed25519 signer sets for
  peer identity. `peer_id` is an Ed25519 public key here from day one so the
  two identity models do not need reconciling after 278 tasks already carry
  the wrong shape.

  ## The invariant that matters

  `next_seq/0` must never return the same value twice for this peer, across
  restarts, crashes, and rolled-back transactions. Gaps are harmless: IDs stay
  distinct. Reuse is fatal: two distinct events mint the same ID and peers
  silently disagree.
  """

  @typedoc "Ed25519 public key, exactly 32 bytes."
  @type peer_id :: <<_::256>>

  @typedoc "Strictly monotone per-peer operation counter. Never reused."
  @type origin_seq :: pos_integer()

  @doc "This peer's stable Ed25519 public key."
  @callback peer_id() :: peer_id()

  @doc "The next unused origin sequence value for this peer."
  @callback next_seq() :: origin_seq()

  @doc """
  Wall-clock milliseconds, stamped once at origin.

  Must be read exactly once by the originating peer and then carried with the
  event. A receiving peer that re-reads its own clock derives a different ID
  for the same logical event.
  """
  @callback origin_wall_ms() :: non_neg_integer()

  def adapter do
    Application.get_env(:spruce_goose, :identity_adapter, SpruceGoose.Identity.Local)
  end

  def peer_id, do: adapter().peer_id()
  def next_seq, do: adapter().next_seq()
  def origin_wall_ms, do: adapter().origin_wall_ms()

  @doc """
  A fresh origin dot: this peer, its next unused sequence value, and the
  wall-clock stamp that travels with the event.
  """
  def dot do
    %{
      peer_id: peer_id(),
      origin_seq: next_seq(),
      origin_wall_ms: origin_wall_ms()
    }
  end
end
