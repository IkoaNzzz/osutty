# Sidecar completion audit

Audit date: 2026-07-25.

## Requirement-to-evidence matrix

| Requirement | Implementation | Evidence |
| --- | --- | --- |
| Fork and clone Ghostty | `origin` is `IkoaNzzz/osutty`; `upstream` is `ghostty-org/ghostty`; work is on `feature/otty-sidecar`. | Remote and branch inspection. |
| Research the real Otty UI first | Window layout, all four panels, interactions, and Otty's port-detection miss are recorded from Accessibility/UI inspection. | [`OTTY_RESEARCH.md`](OTTY_RESEARCH.md). |
| Window-level right Sidecar | `SidecarHostModifier` overlays one inset floating card on the terminal-content region, follows `lastFocusedSurface`, and stays below titlebars, tabs, and window-level banners without resizing the grid. | Debug build plus live Computer Use close/open comparison. |
| Native Otty-like presentation | SwiftUI/AppKit, SF Symbols, hover-revealed trailing titlebar toggle, `⌃⌘S`, Command Palette actions, material card, spring-driven moving tab capsule, compact panel controls, segmented Git actions, independent Files disclosure/selection, menus, commit window, folder picker, and Quick Look. | Live Otty/Osutty Computer Use comparison and feature sources. |
| Info | cwd, copy/reveal/editor actions, bounded foreground process tree, durations, and per-process listening sockets. | Unit tests plus live Python `127.0.0.1:8765` verification. |
| Outline | Bounded core semantic-command snapshot, cwd grouping, metadata, exit/duration display, and stable-row jump. | Parser tests plus live scrollback jump. |
| Git | porcelain-v2 state, diff totals, stage/unstage/all, commit, fetch/pull/push/merge/rebase, cancellation, prompt suppression, and timeouts. | Real temporary repositories cover unborn HEAD, conflicts, detached HEAD, no remote, and ahead/behind. |
| Files | one-level lazy tree, hidden files, parent/folder navigation, capped cancellable search, selection, context actions, and system Quick Look. | Unit tests plus live repository search/preview pass. |
| Multiple panes | One Sidecar follows the last-focused terminal without duplicating per pane. | Live repo/home horizontal-split pass. |
| Terminal input safety | Files' Space monitor activates only for the selected focused file row. | Live terminal-Space and Quick Look open/close pass. |
| Theme compatibility | Production `SidecarChrome` derives light/dark environment, background, opacity, material, border, and shadow from Ghostty config. | Offscreen production render passes for exact 3024 Day/Night backgrounds and opaque readable material over a `0.62` terminal background; default theme also passed live Computer Use. |
| Performance | Hidden subtree creates no pollers; work is bounded/off-main-thread; Release comparison shows no persistent hidden CPU or memory cost. | [`PERFORMANCE.md`](PERFORMANCE.md). |
| Upstream independence | Feature logic remains concentrated in new directories, with the existing app touched through the small adapter list documented in `IMPLEMENTATION.md`. | Adapter inspection; current upstream is the same base commit. |
| macOS/iOS build safety | Sidecar is AppKit-only and excluded from the iOS synchronized group. | macOS Debug/Release builds, full tests, and isolated iOS simulator build. |

## Git edge-state coverage

The Git service tests use real repositories rather than parser fixtures alone:

- unborn `main`: stage, per-file unstage, unstage-all, and staged numstat;
- normal committed repository: clean, dirty, stage, unstage, and commit;
- merge conflict: conflict classification and action exclusion;
- detached HEAD and no remote/upstream;
- local bare remote plus peer clone: simultaneous `ahead=1`, `behind=1`;
- active process cancellation and timeout, both returning within two seconds.

Remote authentication, user-defined hooks, signed commits, submodules, and
server-side rejection depend on external configuration. The implementation
surfaces Git's error text, disables interactive credential prompts, and
applies a 60-second mutation/network timeout, but does not pretend those
external systems were exhaustively simulated.

## UI automation note

The primary functional pass was completed through Computer Use while the
macOS window service was available; it covered all panels, split focus,
floating overlay layout, Outline jump, Git/commit UI, Files search, and Quick
Look.

A permanent `SidecarUITests` case also compiles and is prepared to exercise
the View menu, all four tab identifiers, 3024 Day, 3024 Night, and transparent
background screenshots. A later Computer Use rerun successfully captured the
real Debug app, toggled the hover-only titlebar target, switched panels, and
verified that the terminal grid did not move. To keep theme coverage
independent of host window capture, the unit suite also renders the same
production `SidecarChrome` offscreen with the exact installed 3024 Day/Night
background values and verifies luminance, opaque material alpha, and opacity
clamping.

## Known intentional boundaries

- Files is read-only; it does not delete, rename, or edit user files.
- Pull is fast-forward-only.
- Conflict resolution remains in the terminal/editor; conflicted rows cannot
  be staged by mistake from the Sidecar.
- The Sidecar width is window-scoped but is not yet encoded into Ghostty's
  restored terminal state.
- Normal launches remain hidden by default; automated visibility should be
  driven through the shared state, menu, titlebar target, or `⌃⌘S`, not passed
  as a Ghostty CLI configuration field.
