# AGENTS.md — Engineering rules for DWI

These rules bind every contributor to this repository, human or AI, and every
agent thread spawned to work on it. They are not advisory.

## Operational constraints (apply to every task)

1. **Minimal viable solution first.** Execute simple tasks with the minimum
   required logic and code. Do not add unsolicited architecture, abstractions,
   or premature optimisation.
2. **Ambiguity handling (zero-assumption policy).** If requirements,
   parameters, or intent are ambiguous or incomplete, stop immediately and ask
   targeted clarifying questions before executing. Never guess or interpolate
   missing specifications.
3. **Strict scope adherence.** Modify only the exact files, functions, or text
   explicitly requested. Do not refactor adjacent code, update styles, or alter
   working dependencies unless instructed.
4. **Pre-delivery verification checklist.** Before returning final output,
   review it step-by-step against the original request. Validate syntax, logic,
   and edge cases so the solution is complete, functional, and strictly scoped.

## Mandatory engineering rules

These reproduce the project's master plan, §51.

1. **Never claim behaviour without inspecting source or authoritative
   documentation.** Repository, file, symbol and version, or a reproducible
   probe. No exceptions, no "it is well known that".
2. **Never change public API without an ADR.** API changes are recorded in
   `docs/architecture.md` (ADR) and `docs/api-proposal.md` before code lands.
3. **Never modify the Dart SDK during package research phases.** Research reads
   sources; it does not patch them.
4. **Never modify the Flutter SDK to solve a Dart-level problem prematurely.**
5. **Every implementation must have tests.** A feature without a test is not
   done.
6. **Every concurrency claim requires a reproducible benchmark or test.**
7. **Web JS and Web Wasm are considered separately.** A result from `dart2js`
   says nothing about `dart2wasm`.
8. **Never assume Chrome behaviour equals Safari or Firefox.** Browser-specific
   behaviour is measured per engine and recorded in `docs/browser-matrix.md`.
9. **Do not expose browser APIs through the public Dart API unnecessarily.**
   `package:web` types stay behind the platform package boundary.
10. **Preserve isolate-style no-shared-mutable-state semantics by default.**
    Cross-boundary data is copied or explicitly transferred, never shared.
11. **Generated code must be deterministic.** Same input, byte-identical output.
12. **Worker failures must never silently disappear.** Every failure path ends in
    a typed error delivered to the caller.
13. **Workers must always have defined lifecycle cleanup.** Spawn has an owner;
    termination, timeout and page teardown are handled.
14. **Public APIs require documentation.** Dartdoc on every exported declaration,
    plus an example in `examples/`.
15. **Performance optimisations require before/after benchmarks.**
16. **Prefer incremental PRs.** One concern per change.
17. **Do not emulate unsupported behaviour deceptively.** If the web cannot match
    a native semantic, say so in `docs/limitations.md`.
18. **Clearly document semantic differences from `dart:isolate`.**

## Agent coordination protocol

- Each agent owns a disjoint set of `write_paths`. Never write outside your
  assignment; report a needed change to the coordinator instead.
- Research agents are read-only with respect to the repository except for their
  own report file.
- Architecture agents consume reports; they may not invent facts that no report
  supports. Where evidence is missing, write "unresolved" rather than assuming.
- Implementation agents implement the approved ADR only. They may not redesign a
  public API on their own initiative.
- Testing agents actively try to break the implementation; a test suite that only
  exercises the happy path is incomplete.
- Every agent ends its report with: what was verified, what was not, and what it
  could not determine.

## Terminology

Until compatibility is proven, describe DWI as **worker-backed, isolate-like
concurrency**, not as "isolates". Compatibility levels are defined in the master
plan (§52) and tracked in `docs/compatibility-matrix.md`.
