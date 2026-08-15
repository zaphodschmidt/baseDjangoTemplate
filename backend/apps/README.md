# `apps/` — the blessed core, and the rule about arrows

Every backend feature lives here, one directory per app. The point of the
structure is that deleting a feature is a migration rather than an archaeology
project, and what decides that is **the direction of the dependencies**, not the
directory layout.

## The blessed core

The nouns everything else hangs off. **Adding one is a decision, not a
convenience** — anything in this list becomes something no feature can be
deleted without consulting.

| App | Holds |
|---|---|
| `core` | the health endpoint and the project-wide pagination class. Add the real nouns — user, project, tenant — as you define them. |

Keep this table current. It is the only place the rule below is checkable.

## The rule

**Dependencies point one way: feature → core, never the reverse, never
feature ↔ feature.**

1. A feature app may import from and FK into `core` freely. **`core` never
   imports from or FKs into a feature.** One backwards arrow converts deleting
   that feature from one migration into an audit of every call site.
2. **A sibling FK (feature → feature) is a claim that the two are not
   independent.** Before adding one, ask whether they are really one app. If it
   is genuinely needed it is allowed — with a comment on the field naming the
   dependency and the deletion order it implies (the pointing app dies first).
3. **`on_delete` is a decision.** `PROTECT` across app boundaries; `CASCADE`
   only *within* an app, where the child is meaningless without the parent. A
   cross-app `CASCADE` means deleting a row in one feature silently destroys
   data in another.
4. **No `GenericForeignKey`.** Nothing enforces the target exists, nothing
   PROTECTs it, nothing shows up when you plan the delete. If a model must point
   at one of several things: a nullable FK per target, plus a `CheckConstraint`
   that exactly one is set.
5. **Imports follow the FKs.** An app may import from `core` and from apps it
   already FKs into, nothing else. Need a sibling's *behavior* without a data
   dependency? Call a function it deliberately exposes. No signals — an implicit
   listener is a dependency nobody can find by grepping.

## Layer files

Create each on the *second* use, never in anticipation of one. `models.py`,
`domain.py`, `querysets.py`, `services.py`, `views.py`, `serializers.py`,
`tasks.py` — what belongs in each is the table in `CLAUDE.md § Where logic goes`.
