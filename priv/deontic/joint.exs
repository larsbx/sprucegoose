# SPEC_deontic_joint — keel-language embodiment (Elixir), exhaustively verified.
# Mirrors joint.py: the canonical norm row and one-pass joint grading.
# Run: elixir joint.exs  (exit 0 iff all laws hold)
#
# Like joint.py, this does NOT reimplement the two overlays. It loads the
# certified deontic.exs definition half and calls it, so agreement is by
# construction and J8/J9 check the wiring rather than a transcription.
#
# The enumeration claim is the same one joint.py makes and J2 proves: the raw
# norm-row product is far too large to enumerate pairwise, so the pipeline is
# first shown to read guards only through `applicable`. That factorization is
# what licenses enumerating the projections, each of which is total.

defmodule Loader do
  @marker "# ========================= exhaustive verification ========================"

  def load(filename) do
    path = Path.join(__DIR__, filename)
    source = File.read!(path)

    unless String.contains?(source, @marker) do
      IO.puts("FAIL: #{filename} has no verification marker; refusing to guess")
      System.halt(1)
    end

    source |> String.split(@marker) |> hd() |> Code.eval_string([], file: path)
    :ok
  end
end

Loader.load("deontic.exs")

defmodule Joint do
  # -- The canonical norm row ---------------------------------------------
  # guards are three-valued: true = discharged, false = refuted, nil = unknown.
  @tri [true, false, nil]
  @weights [0, 1, 2]

  def tri, do: @tri
  def weights, do: @weights
  def guard_states, do: for(t <- @tri, p <- @tri, b <- @tri, do: {t, p, b})

  @doc """
  Fail closed: a norm enters the fold only on discharged evidence.

  Unknown is not permission. The blocker must be known absent, not merely
  unproven, so an unknown blocker keeps the norm out of the fold.
  """
  def applicable({true, true, false}), do: true
  def applicable(_), do: false

  # Neutral makes no claim, so it carries no weight; that is what keeps it the
  # fold identity regardless of the weight written on the row.
  def embed(:required, w), do: {{2, w}, {0, 0}}
  def embed(:encouraged, w), do: {{1, w}, {0, 0}}
  def embed(:discouraged, w), do: {{0, 0}, {1, w}}
  def embed(:forbidden, w), do: {{0, 0}, {2, w}}
  def embed(:neutral, _w), do: {{0, 0}, {0, 0}}

  def lexmax(x, y), do: if(x >= y, do: x, else: y)

  def fold_state(rows) do
    rows
    |> Enum.filter(&applicable(&1.guards))
    |> Enum.reduce({{0, 0}, {0, 0}}, fn r, {c, o} ->
      {cc, oc} = embed(r.value, r.weight)
      {lexmax(c, cc), lexmax(o, oc)}
    end)
  end

  defp ladder_of(r), do: {r.scope, r.epoch, r.grade}

  @doc "One pass over a norm multiset: filter, fold, resolve, then ladder."
  def joint(rows, act) do
    live = Enum.filter(rows, &applicable(&1.guards))
    {c, o} = fold_state(live)

    case Deontic.resolve_w({c, o}) do
      :conflict -> break_conflict(live, act)
      base -> base
    end
  end

  defp break_conflict(live, act) do
    commits = Enum.filter(live, &(&1.value == :required))
    omits = Enum.filter(live, &(&1.value == :forbidden))

    verdicts =
      for w <- commits, l <- omits do
        case Deontic.precedence(ladder_of(w), ladder_of(l), act) do
          0 -> :refuse
          1 -> :required
          2 -> :forbidden
        end
      end

    cond do
      # any undecided pair refuses the whole set
      :refuse in verdicts -> :refuse
      # opposed pairs disagreeing refuses
      length(Enum.uniq(verdicts)) != 1 -> :refuse
      true -> hd(verdicts)
    end
  end

  def row(value, opts \\ []) do
    %{
      value: value,
      weight: Keyword.get(opts, :weight, 0),
      guards: Keyword.get(opts, :guards, {true, true, false}),
      scope: Keyword.get(opts, :scope, MapSet.new([:a, :b, :c])),
      epoch: Keyword.get(opts, :epoch, 0),
      grade: Keyword.get(opts, :grade, {0, 0})
    }
  end

  @doc "Authorization through the joint pipeline. Refusal never authorizes."
  def authorized(rows, act) do
    joint(rows, act) in [:required, :encouraged, :neutral, :neutral_gated]
  end
end

# ========================= exhaustive verification ========================
defmodule Verify do
  import Joint

  def law(name, ok, note \\ "") do
    IO.puts("#{if ok, do: "PASS", else: "FAIL"} #{name}#{if note != "", do: " — " <> note, else: ""}")
    ok
  end

  # Reconstruct the ladder data. This is data, not semantics: the deciding
  # functions still come from the certified deontic.exs.
  defp ladder_rows do
    scopes =
      for bits <- 0..7 do
        MapSet.new(
          Enum.filter([:a, :b, :c], fn x ->
            idx = Enum.find_index([:a, :b, :c], &(&1 == x))
            Bitwise.band(bits, Bitwise.bsl(1, idx)) != 0
          end)
        )
      end

    for s <- scopes, e <- 0..2, t <- 0..1, d <- 0..1, do: {s, e, {t, d}}
  end

  defp as_row({a, v, w}, ladder \\ {MapSet.new([:a, :b, :c]), 0, {0, 0}}) do
    {scope, epoch, grade} = ladder
    guards = if a, do: {true, true, false}, else: {true, true, true}
    %{value: v, weight: w, guards: guards, scope: scope, epoch: epoch, grade: grade}
  end

  def run do
    hs = Deontic.h()
    acts = [:a, :b, :c]
    guards = guard_states()
    fold_proj = for a <- [true, false], v <- hs, w <- weights(), do: {a, v, w}
    claims = for s <- 0..2, w <- 0..2, do: {s, w}
    triples = for x <- fold_proj, y <- fold_proj, z <- fold_proj, do: [x, y, z]
    pairs = for x <- fold_proj, y <- fold_proj, do: [x, y]
    inert = for v <- hs, w <- weights(), do: {false, v, w}
    rows = ladder_rows()

    guard_subs =
      for g1 <- guards, g2 <- guards, applicable(g1) == applicable(g2), do: {g1, g2}

    refusing =
      for n1 <- rows, n2 <- rows, act <- acts, Deontic.precedence(n1, n2, act) == 0 do
        {n1, n2, act}
      end

    codomain = [:required, :encouraged, :neutral, :neutral_gated, :discouraged, :forbidden, :refuse]

    results = [
      law(
        "J0 certificates loaded, not transcribed",
        function_exported?(Deontic, :resolve_w, 1) and function_exported?(Deontic, :precedence, 3) and
          length(hs) == 5,
        "deontic.exs supplies the semantics used below"
      ),
      law(
        "J1 guards fail closed",
        Enum.all?(guards, fn g -> applicable(g) == (g == {true, true, false}) end) and
          not Enum.any?(guards, fn {t, p, b} = g ->
            applicable(g) and (is_nil(t) or is_nil(p) or is_nil(b))
          end),
        "exactly 1 of #{length(guards)} guard states admits a norm; unknown never admits"
      ),
      law(
        "J2 guards enter only through applicable",
        Enum.all?(guard_subs, fn {g1, g2} ->
          Enum.all?(fold_proj, fn proj ->
            joint([%{as_row(proj) | guards: g1}], :a) == joint([%{as_row(proj) | guards: g2}], :a)
          end)
        end),
        "#{length(guard_subs) * length(fold_proj)} substitutions; this is what makes " <>
          "projection enumeration sound rather than sampling"
      ),
      law(
        "J3 weighted fold assoc+comm+idem",
        Enum.all?(for(x <- claims, y <- claims, z <- claims, do: {x, y, z}), fn {x, y, z} ->
          lexmax(lexmax(x, y), z) == lexmax(x, lexmax(y, z))
        end) and
          Enum.all?(for(x <- claims, y <- claims, do: {x, y}), fn {x, y} ->
            lexmax(x, y) == lexmax(y, x)
          end) and Enum.all?(claims, &(lexmax(&1, &1) == &1)),
        "lex-max on (strength, weight) keeps the monoid laws after the extension"
      ),
      law(
        "J4 neutral is the fold identity at every weight",
        Enum.all?(for(v <- hs, w <- weights(), nw <- weights(), do: {v, w, nw}), fn {v, w, nw} ->
          fold_state([row(v, weight: w), row(:neutral, weight: nw)]) ==
            fold_state([row(v, weight: w)])
        end),
        "a neutral row carries no claim, so its weight cannot leak into the state"
      ),
      law(
        "J5 joint total over all fold-projection triples",
        Enum.all?(triples, fn t -> joint(Enum.map(t, &as_row/1), :a) in codomain end),
        "#{length(triples)} triples, every result in the declared codomain"
      ),
      law(
        "J6 order-independent over norm multisets",
        Enum.all?(triples, fn t ->
          joint(Enum.map(t, &as_row/1), :a) == joint(Enum.map(Enum.reverse(t), &as_row/1), :a)
        end),
        "#{length(triples)} triples reversed; folding is a multiset operation"
      ),
      law(
        "J7 inapplicable rows are inert",
        Enum.all?(pairs, fn p ->
          base = joint(Enum.map(p, &as_row/1), :a)
          Enum.all?(inert, fn d -> joint(Enum.map(p, &as_row/1) ++ [as_row(d)], :a) == base end)
        end),
        "#{length(pairs) * length(inert)} cases, every pair against every inert row; " <>
          "J3 associativity lifts pairwise inertness to any multiset"
      ),
      law(
        "J8 agrees with the deontic overlay at equal weight",
        Enum.all?(
          for(a <- hs, b <- hs, c <- hs, do: [a, b, c])
          |> Enum.reject(&(:required in &1 and :forbidden in &1)),
          fn vs ->
            flat =
              case joint(Enum.map(vs, &row(&1, weight: 1)), :a) do
                :neutral_gated -> :neutral
                other -> other
              end

            flat == Deontic.combine(vs)
          end
        ),
        "all 125 triples minus the conflict cases; weight ties collapse to neutral"
      ),
      law(
        "J9 agrees with the precedence ladder on conflict",
        Enum.all?(
          for(n1 <- rows, n2 <- rows, act <- acts, do: {n1, n2, act}),
          fn {{s1, e1, g1} = n1, {s2, e2, g2} = n2, act} ->
            expected =
              case Deontic.precedence(n1, n2, act) do
                0 -> :refuse
                1 -> :required
                2 -> :forbidden
              end

            joint(
              [
                row(:required, weight: 1, scope: s1, epoch: e1, grade: g1),
                row(:forbidden, weight: 1, scope: s2, epoch: e2, grade: g2)
              ],
              act
            ) == expected
          end
        ),
        "#{length(rows) * length(rows) * length(acts)} conflict triples resolved by the ladder alone"
      ),
      law(
        "J10 conflict iff opposed binding applicable claims",
        Enum.all?(triples, fn t ->
          live_values = for({a, v, _} <- t, a, do: v)

          (Deontic.resolve_w(fold_state(Enum.map(t, &as_row/1))) == :conflict) ==
            (:required in live_values and :forbidden in live_values)
        end),
        "guarded-out rows cannot manufacture or suppress a conflict"
      ),
      law(
        "J11 weight never breaks a conflict",
        Enum.all?(
          for(w1 <- weights(), w2 <- weights(), e <- 0..2, t <- 0..1, d <- 0..1,
            do: {w1, w2, e, {t, d}}
          ),
          fn {w1, w2, e, g} ->
            joint(
              [
                row(:required, weight: w1, epoch: e, grade: g),
                row(:forbidden, weight: w2, epoch: e, grade: g)
              ],
              :a
            ) == :refuse
          end
        ),
        "with the ladder tied, no weight pair decides; only the ladder may"
      ),
      law(
        "J12 authorization sound through the joint pipeline",
        not authorized([row(:forbidden, weight: 2)], :a) and
          not authorized([row(:required, weight: 2), row(:forbidden, weight: 2)], :a) and
          Enum.all?(for(v <- hs, w <- weights(), do: {v, w}), fn {v, w} ->
            authorized([row(v, weight: w)], :a) == (Deontic.v(v) >= 0.5)
          end) and
          Enum.all?(refusing, fn {{s1, e1, g1}, {s2, e2, g2}, act} ->
            Enum.all?(for(w1 <- weights(), w2 <- weights(), do: {w1, w2}), fn {w1, w2} ->
              not authorized(
                [
                  row(:required, weight: w1, scope: s1, epoch: e1, grade: g1),
                  row(:forbidden, weight: w2, scope: s2, epoch: e2, grade: g2)
                ],
                act
              )
            end)
          end),
        "forbidden never authorizes; all #{length(refusing) * 9} refusal-and-weight " <>
          "combinations never authorize; discouraged gates, not blocks"
      )
    ]

    if Enum.all?(results) do
      IO.puts(
        "\nRESULT: all #{length(results)} laws hold by total enumeration over the projections " <>
          "J2 licenses (#{length(guards)} guard states, #{length(fold_proj)} fold projections, " <>
          "#{length(rows)} ladder rows) — BEAM embodiment agrees with the Python certificate."
      )

      System.halt(0)
    else
      IO.puts("\nRESULT: FAILURE — joint model refuted.")
      System.halt(1)
    end
  end
end

Verify.run()
