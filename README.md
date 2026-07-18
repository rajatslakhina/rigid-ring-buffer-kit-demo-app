# RigidRingBufferKit — Demo App

**Watch a noncopyable ring buffer run a live telemetry pipeline — then break its drain loop on purpose and watch every dropped event get accounted for.**

This is the runnable companion to [`rigid-ring-buffer-kit`](https://github.com/rajatslakhina/rigid-ring-buffer-kit), a fixed-capacity `~Copyable` telemetry ring buffer inspired by Swift 6.4's SE-0527 (`RigidArray`/`UniqueArray`). The library repo holds the design, the ownership proofs, and the benchmark harness; this repo holds the SwiftUI app that lets you *feel* the design:

- **Pipeline tab** — a live producer pushes simulated telemetry events through the actor-isolated `EventPipeline`. Watch occupancy breathe against fixed capacity, then flip the "drain loop running" toggle off to simulate a stalled consumer: with `.dropOldest` the buffer pins at capacity and evictions climb; with `.rejectNewest` rejections climb instead. Every counter obeys the library's conservation law (`pushed == drained + evicted + remaining`) in real time.
- **Benchmark tab** — runs the library's four-scenario comparison (rigid vs. COW, steady-state and snapshot patterns) with 120k reference-payload events per scenario, on your hardware, and draws the results as bars.

## Why this matters

Buffer overflow behavior is invisible in code review and brutal in production. This demo makes the failure modes *visible and interactive*: you can watch exactly what an observability SDK's buffer does when the upload loop stalls, and see why a named overflow policy plus honest metrics beats an unbounded queue that hides the problem until memory pressure kills the app. The consuming side also demonstrates the repo split done right: this app depends on the library **as a remote Swift Package by its GitHub URL** — the same way any third-party consumer would — not as a local path reference.

## How to run it

1. Clone this repo and open `Demo.xcodeproj` in Xcode 15 or later.
2. Xcode will resolve the remote package `rigid-ring-buffer-kit` from GitHub automatically (File → Packages → Update to Latest Package Versions if it doesn't).
3. Select the `Demo` scheme, pick any iOS 17+ Simulator, and Build & Run.
4. On the Pipeline tab press **Start**, let it run a few seconds, then toggle **Drain loop running** off and watch the eviction counter.

## Honest verification status

This project was authored and pushed by an automated pipeline run, and this section states exactly what was and wasn't verified:

- **Verified:** the library this app consumes passed `swift build` and `swift test` (36/36 tests) on Swift 6.0.3/Linux in this run; `DemoApp.swift` passed a `swiftc -parse` syntax check; `project.pbxproj` was script-checked for balanced braces/parens; the shared scheme is XML-validated; a force-unwrap scan found none in either repo.
- **Not verified — a live Simulator run did not happen this run.** The pipeline's rules require checking the screen before driving Xcode, and the first screenshot showed the machine's owner mid-session in Xcode: the real `THDConsumer` (HomeDepotApp) project actively installing to an iPhone 17 Pro Max Simulator on branch `fix/observability-span-end-race-task-mainactor-v2`. Driving Xcode at that moment risked interfering with live work, so the run/screenshot step was deliberately skipped. That is also why there are no screenshots in this README yet — screenshots here will only ever be real captures of the app running, never mockups.

If you run it and hit anything unexpected, an issue on this repo is welcome — the library's test suite is the contract, and a repro that violates it is a real bug.

## The library it consumes

Design decisions, rejected alternatives, ownership invariants, measured benchmark table, and the full test inventory live in the library repo's README: **[rigid-ring-buffer-kit](https://github.com/rajatslakhina/rigid-ring-buffer-kit)**.

## License

MIT
