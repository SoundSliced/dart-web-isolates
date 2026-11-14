# Tree-shaking probe

Checks that the generated DWI worker keeps every annotated task body under
dart2js optimisation (completion-plan tranche A8, critical-review gate 5). Not a
shipped package.

## Inputs

`lib/tasks.dart` and the `src/` files it imports: seven annotated shapes (an
export barrel, a `part` file, a top-level const table, an async task, a local
function, a transitive helper) and one unannotated, unreferenced function.

## Run

```bash
tooling/tree_shaking_probe/run.sh
```

It runs `dart run dwi_builder:dwi build`, then `dart compile js` at `-O1`, `-O2`
and `-O4` on the generated entrypoint, and greps each output for a unique
sentinel string per task.

## Outputs and exit codes

- The temp directory holding the builder log and the compiled outputs (printed).
- `0`: every annotated sentinel is present and the unreferenced sentinel is
  absent in every artefact.
- `1`: a sentinel is missing or the control was kept. Each finding is printed as
  `MISSING` or `NOT DROPPED`.

## Scope

dart2js only. dart2wasm is not measured here (AGENTS.md rule 7). Other library
shapes are not covered; the claim stays limited to the shapes listed above
(`docs/limitations.md` item 13).
