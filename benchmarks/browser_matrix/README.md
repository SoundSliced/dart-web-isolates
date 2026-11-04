# DWI browser matrix harness

Reproducible stress and benchmark harness for the shipped DWI runtime (v0.4).
It measures one engine per invocation and writes environment-stamped JSON
evidence.

## What it measures

| Metric | How |
| --- | --- |
| Cold start | first `Dwi.run` after `Dwi.configure`, including worker spawn and `ready` |
| Warm dispatch | 50 sequential `Dwi.run` round trips, median |
| Copy vs transfer | 64 KiB, 1 MiB, 8 MiB through `sumTyped` (copy) and `sumTransferable` (`DwiTransferableBytes`), 7 runs each, median; every transfer is checked for sender detachment |
| Queued cancellation | a second call is cancelled while a `slow(300)` task holds the only worker |
| Running cancellation | `spin(3000)` is cancelled 100 ms in; the worker is terminated |
| Sustained load | 100 concurrent calls through `maxWorkers: 4`, `maxQueuedTasks: 128`; checks every result |
| Crash and restart | `dieAfter` answers then closes the worker's scope; the next call is timed with heartbeat detection on |
| UI responsiveness | 10 ms timer ticks during a 300 ms worker task, with a main-thread spin as control |

All measurements use the public `package:dwi` API only, so the harness measures
what ships rather than a private shortcut.

## Running it

```bash
cd benchmarks/browser_matrix
dart pub get
dart run run.dart --engine=chrome --runs=3
```

The runner:

1. runs `dart run dwi_builder:dwi build --force` to generate and compile the
   worker;
2. compiles `web/main.dart` with `dart compile js -O2`;
3. serves `web/` on an ephemeral loopback port;
4. loads the page in headless Chrome over CDP `runs` times;
5. writes `audit/evidence/browser-matrix-<engine>-<date>.json` with every run,
   the environment and a summary (median/min/max per metric).

Generated outputs (`lib/dwi_tasks.g.dart`, `web/dwi/`, `web/main.dart.js`,
`.dwi/`) are build artefacts and stay out of git.

## Engine support

Only Chrome is automated. Each other engine must be recorded as unverified with
the exact reason, never filled in from Chrome (AGENTS.md rule 8):

| Engine | State | Reason on the measurement machine (2026-11-04) |
| --- | --- | --- |
| Chrome | measured | `Google Chrome 156.0.8078.80`, headless with `--no-sandbox` |
| Safari | unverified | `safaridriver` answers `/status`, but session creation is refused: "You must enable 'Allow remote automation' in the Developer section of Safari Settings". Enabling it is an interactive admin step. |
| Firefox | unverified | not installed |
| Edge | unverified | not installed |

Extending the runner: add a driver branch in `run.dart` that navigates to the
served page, reads `document.title`, and returns the decoded JSON. The page
already reports everything else.

## Reporting rules

Report the median and the spread over at least three runs; name the machine, OS,
browser version and Dart version; never score an engine that was not run.
