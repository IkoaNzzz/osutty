# Ghostty Otty-style Sidecar

This document describes the implementation on `feature/otty-sidecar`. The
behavioral research and screenshots that informed it are recorded in
[`OTTY_RESEARCH.md`](OTTY_RESEARCH.md).

## User-facing behavior

Move the pointer into the trailing titlebar hot zone to reveal its Sidecar
button, press **Control-Command-S**, open
**View → Toggle Sidecar**, or choose a destination under
**View → Sidecar Panel**. The **Command-Shift-P** command palette also exposes
Toggle Sidecar, Close Sidecar, and direct open commands for all four panels.
Every entry point shares the same window-scoped state. The Sidecar belongs to
the terminal window and follows its last-focused pane.

- **Info** shows the current directory, foreground process, parent shell, and
  listening TCP ports. Path copy, Finder reveal, and installed-editor actions
  use native macOS APIs.
- **Outline** lists up to 500 commands from Ghostty's OSC 133 semantic prompt
  data. It groups completed commands by working directory and jumps directly
  to the corresponding scrollback row.
- **Git** reads porcelain-v2 status, branch/upstream divergence, remote URL,
  and diff totals. It supports per-file/all stage and unstage, commit in a
  separate native window, fetch, fast-forward-only pull, push, merge, and
  rebase.
- **Files** lazily loads one directory level at a time, optionally shows
  hidden files, supports explicit capped recursive search, can detach from the
  terminal directory, and uses the system Quick Look panel.

The panel chrome follows Otty's compact inspector layout: only the selected
top tab expands to show its title, a spring-driven capsule moves between tabs,
and panel content cross-fades without changing the card geometry. Files uses a
full-width neutral row selection, a separate rotating disclosure control,
`24 pt` rows, and a compact search/action strip. Git places repository
identity, segmented commit/editor controls, and Staged/Unstaged rows in the
same vertical order as Otty.

The Sidecar is a `224 pt`-wide inset material card over the terminal. It does
not participate in the terminal's layout, so opening or closing it never
changes the terminal grid. Its adaptive width is clamped to
`200...min(320, windowWidth × 0.45)` points. The card is mounted on the
terminal-content region rather than the whole window; titlebars, native tabs,
debug warnings, and other window-level status content reserve their natural
height before the card is laid out.

## Isolation boundary

Almost all code lives under:

```text
macos/Sources/Features/Sidecar/
macos/Tests/Sidecar/
docs/sidecar/
```

The intentionally small upstream-facing adapters are:

| File | Change |
| --- | --- |
| `TerminalView.swift` | Call one feature-local view modifier and pass the last-focused surface. |
| `BaseTerminalController.swift` | Own `SidecarState` and route native menu actions. |
| `TerminalCommandPalette.swift` | Append native Sidecar commands alongside Ghostty binding actions. |
| `TerminalWindow.swift` | Host the trailing titlebar toggle using the shared Sidecar state. |
| `AppDelegate.swift` | Call the feature-local View-menu installer without changing `MainMenu.xib`. |
| `Ghostty.App.swift` | Passively record bounded command-finished metadata. |
| `include/ghostty.h` | Append two narrow semantic-outline C APIs. |
| `src/apprt/embedded.zig` | Produce a bounded snapshot and scroll to its stable row. |
| `project.pbxproj` | Exclude the AppKit-only feature from the iOS target. |

At the current audit the adapter changes remain localized to the files above.
Layout, menu construction, models, services, and UI tests otherwise remain in
feature-owned files.

The terminal split model, PTY I/O, renderer loop, Metal callbacks, existing
Inspector, and existing C ABI layouts are unchanged.

## Performance properties

- Hiding the Sidecar removes its panel subtree, so Info, Outline, Git, and
  Files have no timers or polling tasks.
- Info samples a bounded foreground process tree once per second. Socket
  discovery reads only those processes' file descriptors and observes task
  cancellation inside both loops.
- Outline snapshots run every two seconds only while selected, hold the
  renderer mutex for a bounded maximum of 500 semantic commands, and return a
  compact binary payload instead of copying the full scrollback.
- Git refreshes every three seconds only while selected. Complete transactions
  are serialized on one utility queue, so status cannot race a mutation and a
  synchronous `Process` wait never occupies a cooperative Swift executor.
  Read-only commands time out after 15 seconds; mutations/network commands use
  60 seconds. All commands disable interactive credential prompts, and active
  processes terminate when their view task is cancelled.
- Files performs one-level lazy enumeration. Recursive search starts only on
  Return, uses a service separate from ordinary browsing, is cancellable, and
  stops at 500 results.
- All filesystem, Git, process, socket, and outline snapshot work runs away
  from the main actor. SwiftUI publishes only finished snapshots with stable
  identifiers.

The upstream/hidden/visible Release measurements and their limitations are in
[`PERFORMANCE.md`](PERFORMANCE.md).

## Verification

Validated on 2026-07-25:

```sh
zig build -Demit-macos-app=false --summary failures
zig build -Demit-macos-app=false -Doptimize=ReleaseFast --summary failures
macos/build.nu --scheme Ghostty --configuration Debug --action build
macos/build.nu --action test
macos/build.nu --scheme Ghostty --configuration ReleaseLocal --action build

while IFS= read -r -d '' swift_file; do
  swiftlint lint --strict --quiet "$swift_file"
done < <(rg --files -0 \
  macos/Sources/Features/Sidecar \
  macos/Tests/Sidecar \
  macos/GhosttyUITests/SidecarUITests.swift \
  -g '*.swift')

zig fmt --check src/apprt/embedded.zig
git diff --check
```

The resulting universal ReleaseLocal app reports `.ReleaseFast` for its Zig
core and `renderer.generic.Renderer(renderer.Metal)`.

The Sidecar tests cover:

- binary outline decoding, malformed tails, and invalid UTF-8;
- Git porcelain-v2 branch, rename, conflict, untracked, detached-HEAD, and
  numstat parsing;
- real temporary Git repositories through unborn-HEAD stage/unstage-all,
  commit, dirty/clean state, merge conflict, detached HEAD, missing remote, and
  simultaneous ahead/behind state against a local bare remote;
- Git process cancellation and timeout, both completing in under two seconds;
- lazy file ordering, hidden files, case-insensitive recursive search, and
  result caps;
- libproc lookup of the test process and discovery of a spawned Python
  descendant's dynamically allocated loopback listener;
- menu tag/state routing;
- offscreen rendering of the production `SidecarChrome` with Ghostty's exact
  3024 Day (`#f7f7f7`) and 3024 Night (`#090300`) backgrounds, including
  light/dark environment selection and readable opaque material over a
  `0.62` transparent terminal background.

The iOS simulator target also builds with the Sidecar sources excluded:

```sh
env -i "HOME=$HOME" "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
  xcodebuild -project macos/Ghostty.xcodeproj \
  -scheme Ghostty-iOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
```

## Computer Use acceptance pass

The Debug app was exercised through the real macOS UI after closing every
older instance and launching exactly one copy from this worktree:

- View-menu routing opened all four panels.
- In a live horizontal split, the right pane used `~` while the left pane used
  `~/Code/naoki/ghostty`; clicking between them updated Info's directory and
  PID to the last-focused pane without creating a second Sidecar.
- Info followed `cd`, changed from zsh to a spawned Python process, reported
  `127.0.0.1:8765` with the correct PID, and returned to zsh with no listener
  after `Control-C`.
- Outline grouped shell-integrated commands by directory; selecting an older
  command moved the terminal scrollback to its semantic prompt row.
- Git showed `feature/otty-sidecar`, its remote, diff totals, dirty groups,
  stage/commit actions, and the separate native commit window.
- Files lazily expanded the repository, searched by relative path, and gave a
  selected README row keyboard focus. Space opened system Quick Look; a second
  Space closed it and returned to the same row.
- Files row selection and disclosure were exercised independently: selecting
  a directory did not expand it, the disclosure arrow animated the lazy
  children, and neither path showed SwiftUI's blue focus halo.
- The shared tab strip was checked across Info, Outline, Git, and Files; its
  selected capsule and title animate between stable trailing-aligned icons.
- With Files visible and no file-row focus, Space continued to reach the
  terminal. A long search canceled on cwd change and did not block the new
  root from loading.
- Opening and closing the floating card left the terminal prompt and grid at
  the same coordinates.
- The titlebar button was visually absent at rest and remained an accessible
  hit target; Computer Use opened it through that target and `⌃⌘S` closed and
  reopened the same window-scoped Sidecar.

This pass exposed and fixed two focus bugs: a Files-only Space monitor could
previously intercept terminal input, and the Quick Look panel could not close
itself after becoming the key window. It also exposed and fixed recursive
search serializing ordinary directory browsing behind a large filesystem
walk. The final audit additionally fixed a shared Files loading flag race,
unborn-HEAD unstage, Git refresh/mutation interleaving, and unbounded
credential/process waits.

`SidecarUITests` compiles and is prepared to drive the View menu, all four
panels, light/dark luminance checks, and a transparent-background screenshot.
The current layout was also exercised through Computer Use in the real Debug
app: all four panels rendered, the titlebar target toggled the Sidecar, and
`⌃⌘S` completed a close/open cycle. Theme compatibility remains independently
covered by an AppKit/SwiftUI offscreen render of the same production chrome.
See [`COMPLETION_AUDIT.md`](COMPLETION_AUDIT.md) for the exact boundary.

## Updating from upstream

Keep the fork remotes as:

```sh
git remote -v
# origin   https://github.com/IkoaNzzz/osutty.git
# upstream https://github.com/ghostty-org/ghostty.git
```

Then update the feature branch with:

```sh
git fetch upstream
git rebase upstream/main
```

Resolve the small adapter files first; the feature-local files should normally
rebase without conflicts.

At the 2026-07-25 audit, `upstream/main` and this branch's base both resolve to
`4c725242b7db`, so no rebase conflict is currently pending.
