# Sidecar performance verification

Measured on 2026-07-25 on the same macOS host and Ghostty commit
`4c725242b7db`.

## Method

The comparison used two independently built universal `ReleaseLocal` apps:

- upstream Ghostty from an isolated detached worktree at `4c725242b7db`;
- this worktree with the Sidecar changes.

Both apps used a `ReleaseFast` Zig core and `-O` Swift code. The Xcode scheme
also enables coverage instrumentation in `ReleaseLocal`, so the absolute
numbers are conservative; the upstream and feature builds used the same
instrumentation.

Each run used:

- an empty config;
- the same `100 × 30` terminal size and repository working directory;
- `-ApplePersistenceIgnoreState YES`;
- four seconds of launch warm-up;
- 15 one-second `top` samples of the app process.

The visible run used the Info panel because its one-second process/socket
refresh is the most frequent periodic Sidecar workload. The normal product
default remains hidden. Product validation now opens the panel through the
shared Sidecar state or `Control-Command-S`; `GhosttySidecarVisible` must not
be passed as a Ghostty CLI configuration field.

## Results

| Build/state | CPU median | CPU mean, all 15 | CPU mean excluding one shared cold-start spike | Resident-memory range | Threads |
| --- | ---: | ---: | ---: | ---: | ---: |
| Upstream, hidden | 0.0% | 0.14% | 0.00% | 63–70 MiB | 12–13 |
| Sidecar build, hidden | 0.0% | 0.21% | 0.00% | 62–70 MiB | 10–12 |
| Sidecar build, Info visible | 0.2% | 0.48% | 0.21% | 61–67 MiB | 11–12 |

All three runs had one allocator/shell-startup event around sample 11:

- upstream: `2.1%`;
- Sidecar hidden: `3.1%`;
- Info visible: `4.2%`.

The hidden build otherwise recorded fourteen `0.0%` samples, exactly like
upstream. Its `0.07` percentage-point all-sample mean difference is entirely
within that single cold-start event; median, steady-state mean, memory range,
and thread count show no persistent hidden cost.

Info's bounded foreground-process and socket-FD scan adds a process-wide
median of about `0.2%` while visible. This is not a main-thread number:
`top` measures the whole app. The work itself runs on a utility actor and only
publishes its completed snapshot on the main actor.

## Why hidden cost stays at zero

- `SidecarContainer` removes the panel subtree when hidden.
- SwiftUI `.task` lifetimes therefore stop Info, Outline, and Git polling.
- Files has no timer or watcher; it enumerates a directory only on root,
  expansion, reload, or explicit search.
- Git process execution, filesystem enumeration, process/socket inspection,
  and Outline decoding run outside the main actor.
- The renderer, PTY read/write path, Metal callbacks, and split-tree recursion
  are unchanged.
- The core Outline API runs only when the Outline panel requests a bounded
  snapshot. Command metadata records one bounded event per completed command,
  not per terminal byte or frame.

## Cancellation and bounds

- Info checks task cancellation while walking at most 64 descendant
  processes and at most 4096 file descriptors per process.
- Outline returns at most 500 semantic commands.
- Git transactions are serialized on one utility queue. Read-only commands
  time out after 15 seconds; mutations/network commands time out after
  60 seconds; active processes terminate on task cancellation. Automated
  cancellation and timeout tests both complete in under two seconds.
- Files loads one directory level at a time. Explicit recursive search checks
  cancellation on every entry and stops at 500 results.

## Residual performance risks

- A very large Git worktree can still make `git status` or hooks expensive.
  The work is off-main-thread, cancellable, serialized, and bounded by timeout,
  but Ghostty cannot make the underlying repository operation cheap.
- Info's libproc scan is intentionally bounded. A process tree or FD table
  beyond those caps may be incomplete rather than consuming unbounded CPU.
- `ReleaseLocal` coverage instrumentation prevents treating these figures as
  production absolutes. The apples-to-apples hidden comparison and the
  absence of renderer/PTY changes are the relevant regression evidence.
