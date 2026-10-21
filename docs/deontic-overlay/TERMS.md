# Terminology map — v0.3 (domain-specific) -> v0.4 (neutral)

Rationale: the abstractions are applied to isomorphisms *within this system*.
Domain-specific religious vocabulary asserts a correspondence that is not being
claimed and is therefore inaccurate. The mathematics is untouched: same finite
models, same law count, same enumeration. This is a rename, not a redesign.

## The five deontic values (H)

| v0.3     | v0.4          | reading                          |
|----------|---------------|----------------------------------|
| wajib    | `required`    | binding demand to act            |
| mandub   | `encouraged`  | non-binding demand to act        |
| mubah    | `neutral`     | optional / no demand             |
| makruh   | `discouraged` | non-binding demand to refrain    |
| haram    | `forbidden`   | binding demand to refrain        |

## Structure and operations

| v0.3               | v0.4                     | notes                              |
|--------------------|--------------------------|------------------------------------|
| hukm / ahkam       | deontic value(s)         | the elements of H                  |
| ta'arud            | `conflict`               | opposed binding claims             |
| unresolved_conflict| `unresolved_conflict`    | unchanged; already neutral         |
| jazim / ghayr jazim| binding / non-binding    | axis A3                            |
| iqtida' / takhyir  | Demand / Option          | axis A1                            |
| fi'l / tark        | Act / Refrain            | axis A2                            |
| nu (ν)             | `dual`                   | the order-reversing involution     |
| theta (θ)          | `compile`                | Tier x Polarity -> deontic value   |
| rho (ρ)            | `resolve`                | M -> H u {conflict}                |

## Tiers and polarity (from the companion ontology overlay)

| v0.3      | v0.4         | notes                                |
|-----------|--------------|--------------------------------------|
| daruri    | `critical`   | tier rank 2                          |
| haji      | `important`  | tier rank 1                          |
| tahsini   | `refining`   | tier rank 0                          |
| wujud     | `promote`    | liveness pole                        |
| adam      | `prevent`    | safety pole                          |
| maqasid   | objectives   | the ontology overlay generally       |

## Precedence ladder

| v0.3                  | v0.4                | notes                              |
|-----------------------|---------------------|------------------------------------|
| tarjih                | precedence          | the conflict-breaking ladder       |
| jam' / takhsis        | `specificity`       | rung 1: strict scope nesting       |
| naskh                 | `supersession`      | rung 2: later epoch wins           |
| quwwat al-dalil       | `evidence strength` | rung 3                             |
| tasaqut               | mutual fall / refuse| exhaustion -> refuse               |
| qat'i / zanni         | `certain`/`probable`| grade coordinates                  |
| thubut / dalala       | `provenance`/`interpretation` | grade axes               |

## Means/ends transfer

| v0.3                  | v0.4                  | notes                            |
|-----------------------|-----------------------|----------------------------------|
| wasa'il               | means                 | transfer of value to means       |
| sadd al-dhara'i       | `blocking transfer`   | means to a forbidden end         |
| W_IND (indispensable) | `T_NEC` (necessary)   | full inheritance                 |
| W_SUP (supporting)    | `T_AUX` (auxiliary)   | strict attenuation               |
| sabab / shart / mani' | `trigger` / `precondition` / `blocker` | guards          |
| ibaha / hazr          | permission / prohibition default | authorization presumption |
| idhn                  | grant / authorization | kernel term already              |

## What does NOT change

- |H| = 5, |M| = 9, the valence chain {0, .25, .5, .75, 1}
- Every law and its number (L1-L12c, T1-T12)
- Law counts: 18 (deontic.py), 12 (precedence.py), 20 (deontic.exs)
- Fail-closed semantics and the DRAFT lifecycle ceiling

## Note on the historical claim

v0.3's derivation section claimed the five values were read off a classical
juristic taxonomy. v0.4 makes no such claim: the three-axis decomposition is
presented as a definition, and the resulting five-fold structure is a theorem
about that definition. Where the structure happens to coincide with other
normative traditions, that is a remark, not a warrant.
