# SPEC_deontic_core — keel-language embodiment (Elixir), exhaustively verified.
# Mirrors deontic.py + precedence.py: derivation, De Morgan chain, fold/resolve,
# weighted compile, precedence ladder. Pattern-matched, immutable, zero deps.
# Run: elixir deontic.exs  (exit 0 iff all laws hold)
#
# Vocabulary note: stated in neutral deontic-logic terms because it is applied
# to isomorphisms internal to this system. Structural coincidence with any
# external normative tradition is a remark, not a claim.

defmodule Deontic do
  # -- Derivation: three axes -> exactly five inhabitants -----------------
  @axes [{:demand, :act, true}, {:demand, :act, false},
         {:demand, :refrain, true}, {:demand, :refrain, false}, {:option}]
  def name({:demand, :act, true}),       do: :required
  def name({:demand, :act, false}),      do: :encouraged
  def name({:demand, :refrain, true}),   do: :forbidden
  def name({:demand, :refrain, false}),  do: :discouraged
  def name({:option}),                   do: :neutral
  def axes, do: @axes
  def h, do: Enum.map(@axes, &name/1)

  # -- Valence chain and involution dual ----------------------------------
  def v(:forbidden), do: 0.0
  def v(:discouraged), do: 0.25
  def v(:neutral), do: 0.5
  def v(:encouraged), do: 0.75
  def v(:required), do: 1.0
  def dual(:required), do: :forbidden
  def dual(:encouraged), do: :discouraged
  def dual(:neutral), do: :neutral
  def dual(:discouraged), do: :encouraged
  def dual(:forbidden), do: :required

  # -- Aggregation monoid M and resolution --------------------------------
  def e(:required), do: {2, 0}
  def e(:encouraged), do: {1, 0}
  def e(:neutral), do: {0, 0}
  def e(:discouraged), do: {0, 1}
  def e(:forbidden), do: {0, 2}
  def fold({c1, o1}, {c2, o2}), do: {max(c1, c2), max(o1, o2)}
  def resolve({2, 2}), do: :conflict
  def resolve({2, _}), do: :required
  def resolve({_, 2}), do: :forbidden
  def resolve({1, 1}), do: :neutral
  def resolve({1, 0}), do: :encouraged
  def resolve({0, 1}), do: :discouraged
  def resolve({0, 0}), do: :neutral
  def combine(hs), do: hs |> Enum.map(&e/1) |> Enum.reduce({0, 0}, &fold/2) |> resolve()

  # -- Weighted claims: lex-max on {strength, weight} (gap 3) -------------
  def lmax(x, y), do: if(x >= y, do: x, else: y)
  def wclaim_fold(x, y), do: {lmax(elem(x, 0), elem(y, 0)), lmax(elem(x, 1), elem(y, 1))}
  def resolve_w({{2, _}, {2, _}}), do: :conflict
  def resolve_w({{2, _}, _}), do: :required
  def resolve_w({_, {2, _}}), do: :forbidden
  def resolve_w({{1, cw}, {1, ow}}) when cw > ow, do: :encouraged
  def resolve_w({{1, cw}, {1, ow}}) when ow > cw, do: :discouraged
  def resolve_w({{1, _}, {1, _}}), do: :neutral_gated
  def resolve_w({{1, _}, _}), do: :encouraged
  def resolve_w({_, {1, _}}), do: :discouraged
  def resolve_w(_), do: :neutral

  # -- compile' : Tier x Polarity -> {value, weight} ----------------------
  @tier_rank %{critical: 2, important: 1, refining: 0}
  def tier_rank, do: @tier_rank
  def compile_w(:critical, :promote), do: {:required, 2}
  def compile_w(:critical, :prevent), do: {:forbidden, 2}
  def compile_w(:important, :promote), do: {:encouraged, 1}
  def compile_w(:important, :prevent), do: {:discouraged, 1}
  def compile_w(:refining, :promote), do: {:encouraged, 0}
  def compile_w(:refining, :prevent), do: {:discouraged, 0}

  # -- Precedence ladder (gap 1): specificity -> supersession -> evidence --
  def grade_gt({t1, d1}, {t2, d2}), do: {t1, d1} != {t2, d2} and t1 >= t2 and d1 >= d2
  def rung1({s1, _, _}, {s2, _, _}, act) do
    cond do
      strict_subset?(s1, s2) -> if MapSet.member?(s1, act), do: 1, else: 2
      strict_subset?(s2, s1) -> if MapSet.member?(s2, act), do: 2, else: 1
      true -> 0
    end
  end
  defp strict_subset?(a, b), do: MapSet.subset?(a, b) and not MapSet.equal?(a, b)
  def rung2({_, e1, _}, {_, e2, _}), do: (e1 > e2 && 1) || (e2 > e1 && 2) || 0
  def rung3({_, _, g1}, {_, _, g2}), do: (grade_gt(g1, g2) && 1) || (grade_gt(g2, g1) && 2) || 0
  def precedence(n1, n2, act) do
    Enum.find([rung1(n1, n2, act), rung2(n1, n2), rung3(n1, n2)], 0, &(&1 != 0))
  end

  def may_authorize(h), do: h in [:required, :encouraged, :neutral]

  # audit F-6: two-regime means transfer
  # t_nec: necessary means -> full inheritance; t_aux: auxiliary means
  # -> symmetric attenuation (non-identity, so dual-naturality has content)
  def t_nec(h), do: h
  def t_aux(:required), do: :encouraged
  def t_aux(:encouraged), do: :encouraged
  def t_aux(:neutral), do: :neutral
  def t_aux(:discouraged), do: :discouraged
  def t_aux(:forbidden), do: :discouraged

  # audit F-1: independent reference for resolve_w pinning
  def expected_resolve_w({cs, cw}, {os_, ow}) do
    case resolve({cs, os_}) do
      :neutral when cs == 1 and os_ == 1 ->
        cond do
          cw > ow -> :encouraged
          ow > cw -> :discouraged
          true -> :neutral_gated
        end
      base -> base
    end
  end
end

# ========================= exhaustive verification ========================
defmodule Verify do
  import Deontic
  def law(name, ok, note \\ "") do
    IO.puts("#{if ok, do: "PASS", else: "FAIL"} #{name}#{if note != "", do: " — " <> note, else: ""}")
    ok
  end

  def run do
    hs = h()
    claims = for s <- 0..2, w <- 0..2, do: {s, w}
    scopes = for bits <- 0..7, do: MapSet.new(Enum.filter([:a, :b, :c], fn x ->
               Bitwise.band(bits, Enum.find_index([:a, :b, :c], &(&1 == x)) |> then(&Bitwise.bsl(1, &1))) != 0 end))
    grades = for t <- 0..1, d <- 0..1, do: {t, d}
    norms = for s <- scopes, ep <- 0..2, g <- grades, do: {s, ep, g}
    triples = for n1 <- norms, n2 <- norms, a <- [:a, :b, :c], do: {n1, n2, a}

    results = [
      law("L1 derivation exact", length(axes()) == 5 and Enum.sort(hs) == Enum.sort([:required, :encouraged, :neutral, :discouraged, :forbidden])),
      law("L3 dual involution", Enum.all?(hs, &(dual(dual(&1)) == &1))),
      law("L4 dual antitone", Enum.all?(hs, fn a -> Enum.all?(hs, fn b -> (v(a) <= v(b)) == (v(dual(b)) <= v(dual(a))) end) end)),
      law("L5 fix(dual) = {neutral}", Enum.filter(hs, &(dual(&1) == &1)) == [:neutral]),
      law("L6 Lukasiewicz-5 iso", Enum.all?(hs, &(abs(v(dual(&1)) - (1 - v(&1))) < 1.0e-12))),
      law("L7 fold assoc+comm+idem, resolve.e = id",
        Enum.all?(for x <- claims, y <- claims, z <- claims, do: fold(fold(x, y), z) == fold(x, fold(y, z))) and
        Enum.all?(for x <- claims, y <- claims, do: fold(x, y) == fold(y, x)) and
        Enum.all?(hs, &(resolve(e(&1)) == &1))),
      law("L7d combine order-independent",
        Enum.all?(for a <- hs, b <- hs, c <- hs, do: combine([a, b, c]) == combine([c, b, a])),
        "all 125 triples"),
      law("L7e conflict iff binding-vs-binding",
        Enum.all?(for a <- hs, b <- hs, c <- hs, p = [a, b, c],
          do: (combine(p) == :conflict) == (:required in p and :forbidden in p))),
      law("L9 compile-polarity duality",
        Enum.all?([:critical, :important, :refining], fn t ->
          {hw, w} = compile_w(t, :promote); {ha, ^w} = compile_w(t, :prevent); hw == dual(ha) end),
        "same weight, dual value"),
      law("T7 weighted fold assoc",
        Enum.all?(for x <- claims, y <- claims, z <- claims,
          do: wclaim_fold(wclaim_fold(x, y), z) == wclaim_fold(x, wclaim_fold(y, z)))),
      law("T8 weight breaks (1,1) tie",
        Enum.all?(for w1 <- 0..2, w2 <- 0..2 do
          resolve_w({{1, w1}, {1, w2}}) ==
            cond do w1 > w2 -> :encouraged; w2 > w1 -> :discouraged; true -> :neutral_gated end
        end)),
      law("T9 compile' injective",
        (for t <- [:critical, :important, :refining], p <- [:promote, :prevent], do: compile_w(t, p))
        |> Enum.uniq() |> length() == 6),
      law("T1/T2 precedence total + dual",
        Enum.all?(triples, fn {n1, n2, a} ->
          r = precedence(n1, n2, a)
          r in [0, 1, 2] and r == %{0 => 0, 1 => 2, 2 => 1}[precedence(n2, n1, a)] end),
        "#{length(triples)} conflict triples"),
      law("T4 refusal characterized",
        Enum.all?(triples, fn {n1, n2, a} ->
          {_, e1, g1} = n1; {_, e2, g2} = n2
          (precedence(n1, n2, a) == 0) ==
            (rung1(n1, n2, a) == 0 and e1 == e2 and not grade_gt(g1, g2) and not grade_gt(g2, g1)) end)),
      law("L11 authorization sound",
        not may_authorize(:forbidden) and not may_authorize(:conflict) and
        Enum.all?(hs, &(may_authorize(&1) == (v(&1) >= 0.5)))),
      # -- audit F-2: explicit means transfer, three constrained laws ------
      law("L12 T dual-natural (both regimes)",
        Enum.all?(hs, &(t_nec(dual(&1)) == dual(t_nec(&1)))) and
        Enum.all?(hs, &(t_aux(dual(&1)) == dual(t_aux(&1)))),
        "t_aux != id gives the law force"),
      law("L12b blocking transfer (graded)",
        t_nec(:forbidden) == :forbidden and t_aux(:forbidden) == :discouraged and
        not may_authorize(t_nec(:forbidden)) and not may_authorize(t_aux(:forbidden))),
      law("L12c means never outrank ends, strictly attenuated when auxiliary",
        Enum.all?(hs, &(abs(v(t_nec(&1)) - 0.5) <= abs(v(&1) - 0.5))) and
        Enum.all?(hs, &(abs(v(t_aux(&1)) - 0.5) <= abs(v(&1) - 0.5))) and
        abs(v(t_aux(:required)) - 0.5) < abs(v(:required) - 0.5) and
        abs(v(t_aux(:forbidden)) - 0.5) < abs(v(:forbidden) - 0.5)),
      # -- audit F-1: resolve_w pinned over all 81 states + conflict weight-proof
      law("T11 resolve_w pinned over all states",
        Enum.all?(for c <- claims, o <- claims, do: resolve_w({c, o}) == expected_resolve_w(c, o)),
        "all 81 states incl. every strength-2 branch"),
      law("T12 weight never breaks conflict",
        Enum.all?(for w1 <- 0..2, w2 <- 0..2, do: resolve_w({{2, w1}, {2, w2}}) == :conflict))
    ]

    if Enum.all?(results) do
      IO.puts("\nRESULT: all #{length(results)} laws hold by total enumeration (BEAM embodiment agrees with the Python certificate).")
      System.halt(0)
    else
      IO.puts("\nRESULT: FAILURE — model refuted.")
      System.halt(1)
    end
  end
end

Verify.run()
