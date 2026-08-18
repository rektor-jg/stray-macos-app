# Stray

**A macOS menu-bar app that finds what AI coding agents leave behind: stuck processes, orphaned dev servers, memory leaks, and build artifacts that outlived their projects.**

Activity Monitor tells you *something* is eating your CPU. Stray tells you **whose it is, whether it is still doing anything useful, and whether it is safe to kill.**

<sub>Swift 6 · SwiftUI · macOS 14+ · no sandbox, no root, no network</sub>

---

## The problem

A one-line summary of the incident that started this project:

> A script an AI agent wrote in a previous session hung on catastrophic regex backtracking and burned **95% of one core for 6 hours and 51 minutes**. Activity Monitor showed only `Python`. No script name, no context, no owner.

Tracing it took `ps`, a walk up the parent chain, and `sample`. The parent turned out to be an agent session that had been blocked waiting for that script's output the entire time.

Scanning the rest of the machine surfaced something worse:

| PID | Command | Age | RAM | Port |
|---|---|---|---|---|
| 12672 | `npm exec next dev -p 3111` | 4 h 37 m | 654 MB | 3111 |
| 39845 | `npm exec expo start --port 8081` | 59 m | 443 MB | 8081 |

Both had `PPID == 1` — the shell that started them was long dead and `launchd` had adopted them. Neither used measurable CPU, so **neither would ever appear in any "what's slowing down my Mac" list**. They just sat there holding 1.1 GB and two ports.

AI agents generate a new class of system debris, and no existing tool understands it, because no existing tool knows what an *agent session* is.

---

## What it does

Three tabs, each answering a different question.

### Overview — what is AI costing me right now

Live process and memory totals for everything traceable to an agent, CPU-hours accumulated today and this week, a ranked "worth turning off" list, and a disk summary. Every number is labelled with how confidently it can be attributed (see [Attribution](#attribution-how-we-know-it-is-ai)).

### Processes — what is broken right now

Findings from three detectors, coloured by how much you would reclaim, each with a one-sentence recommendation.

| Detector | Signal |
|---|---|
| **Stuck** | high CPU **and** single-threaded **and** zero wakeups **and** zero disk I/O — a loop making no progress |
| **Orphan** | `PPID == 1` **and** a CLI dev tool **and** old — with sockets sampled over time to tell "in use" from "forgotten" |
| **Leak** | RSS climbing monotonically across a 10-minute window |

### Disk — what AI left on the filesystem

Agent data, build caches, package caches, and `node_modules`, each tagged with attribution confidence and whether it is safe to delete. Deletion is available per item or in bulk, behind [several barriers](#deleting-things-safely).

---

## The core insight: stuck has a signature

A CPU threshold on its own is worthless. An Xcode build also sits at 100%, and that is correct behaviour. What separates a stuck process from a busy one is **lack of progress**, and that is measurable:

```
Python    72% CPU   1 thread    0 wakeups     ← spinning
iTerm2    22% CPU   9 threads   209 wakeups   ← healthy
Brave     19% CPU   25 threads  265 wakeups   ← healthy
```

A compiler writes to disk constantly and yields the CPU dozens of times a second. A process buried in regex backtracking does neither. Four conditions checked together — high CPU, one thread, no wakeups, no disk I/O — give high precision without drowning the user in false alarms every time they build something.

---

## Attribution: how we know it is AI

This is the hardest question in the project, and the easiest place to lie with a big number. Two mechanisms, in order of trustworthiness.

### 1. Environment markers — a measurement

Agents set environment variables on the processes they spawn, and environments are inherited through `fork`/`exec`. A process carries them **for its entire life, including after it is orphaned**:

```
CLAUDECODE=1                       ← this is an agent's descendant
CLAUDE_CODE_SESSION_ID=52cefadb-…  ← which session
CLAUDE_PID=2061                    ← what PID that session runs under
```

`KERN_PROCARGS2` returns them alongside the command line, so it is one `sysctl` and no extra cost.

This solves what the process tree cannot. An orphan loses its `ppid` permanently, but it never loses its environment. The two dev servers above were unattributable until Stray started reading it:

```
before:  origin unknown — already an orphan before Stray started
after:   left behind by claude 52cefadb — session PID 2061 still running
```

> **Security note.** Reading another process's environment means walking past live secrets — `CLAUDE_CODE_MESSAGING_TOKEN` sits right next to the markers. The parser reads values only for keys on a closed allowlist, has a second guard rejecting any name containing `TOKEN`/`SECRET`/`KEY`/`AUTH`, and discards everything else in the same loop. There is a test for this.

### 2. Binary name and recorded ancestry — an inference

Used for agent processes themselves and as a fallback. Matching is **exact, not prefix-based**: a prefix match on `cursor` also matched `CursorUIViewService`, an Apple text-input service, and counted it as AI. Anything under `/System/` is now rejected regardless of name.

### Confidence tiers

Numbers from different tiers are **never summed without a label**. The easiest way to produce an impressive-looking figure is to fold in five years of npm cache and call it "AI".

| Tier | Meaning | Example |
|---|---|---|
| 🟢 **measured** | an agent process, its live subtree, or its own directory | `~/.claude`, session scratchpads, `claude.exe` and descendants |
| 🔵 **traced** | recorded ancestry, or a path inside an agent working directory | `DerivedData` pointing at `/scratchpad/` or `.claude/worktrees/` |
| ⚪️ **inferred** | circumstantial project evidence — an estimate, not a measurement | npm cache, `node_modules` in a repo containing `CLAUDE.md` |

Processes orphaned **before Stray started** that carry no environment markers go into a separate "unattributed" bucket and are never counted towards AI. An inflated number would be worse than no number.

---

## Why it has to be a resident app

An orphan loses its parent permanently — `launchd` rewrites `ppid` to 1 and the link to the session that created it is gone. No `ps` run afterwards can recover it.

Stray samples continuously, so it saw the process **while its parent was still alive**, and recorded the ancestry then. That, plus environment markers, is the whole reason this is a daemon rather than a cron script.

---

## Architecture

Everything hangs off one three-second tick.

```
ProcScanner.listPIDs()                     → ~780 PIDs
   │
   ├─ 2 syscalls each                       (~2.3 ms total)
   │     proc_pidinfo(PROC_PIDTASKALLINFO)  → ppid, uid, name, threads, CPU, RSS
   │     proc_pid_rusage(RUSAGE_INFO_V4)    → disk I/O, wakeups
   │
   ├─ own UID only                          → ~780 readable, root processes skipped
   │
   ├─ first time seen?
   │     └─ record metadata ONCE: full command line, start time,
   │        ancestry chain, and agent environment markers
   │
   ├─ append numbers to a ring buffer       (120 samples = 10 minutes)
   │
   └─ cheap candidate filter                → full windows built only for
                                              processes a detector could care about
                    │
                    ▼
            ProcWindow = metadata + time series + subtree + socket history
                    │
                    ▼
            Detectors — pure functions, (window) -> Finding?
                    │
                    ▼
            Policy — ignore list, dedup, notification cooldown
                    │
                    ├─→ SwiftUI menu-bar UI
                    └─→ AI footprint ledger (persisted daily)
```

Four decisions everything else follows from:

**Metadata is stored separately from numbers.** 780 processes × 120 samples is 94,000 records. Keeping strings in each would cost hundreds of MB, so text is recorded once per process and the time series is pure numbers.

**The subtree is the unit, not the process.** `npm exec next dev` is really `npm → node → next-server`, where the top process holds 56 MB and its grandchild holds 531 MB and owns the port. Measuring only the root understated memory tenfold — and killing only the root would have orphaned the children further. `terminateTree` works from the leaves up.

**Detectors are pure functions.** No system access, no state: they take an observation window and return a finding or nothing. That is why 50 tests run in 0.02 seconds. Socket probing is injected rather than called directly — when it was not, a test with a made-up PID hit a real process on the machine and failed for reasons that had nothing to do with the code under test.

**Disk is a different model entirely.** `du` on a 25 GB directory takes seconds, so the disk layer runs on demand and once a day, cached — never in the sampling loop.

---

## Performance

Measured externally with `proc_pid_rusage`, not by the app's own stopwatch:

| | |
|---|---|
| CPU | **0.267%** of one core |
| Memory | 71 MB RSS (21 MB is the core; the rest is the SwiftUI baseline) |
| Sampling tick | ~1 ms of CPU per 3 s |
| Cold start | ~25 ms — one `sysctl` per process for command line and environment |
| Full disk scan | 7.0 s |

A tool for catching resource hogs has to publish its own bill, so the popover footer shows Stray's current CPU usage at all times.

> An earlier version reported this figure from a wall-clock stopwatch around the scan and consequently overstated its own cost by 10×. A tick takes 6–10 ms of wall time but ~1 ms of CPU; the rest is waiting on syscalls. It now measures itself the same way it measures every other process.

---

## Deleting things safely

Killing a process is undone by restarting it. Deleting a directory is undone by nothing. Every item passes four barriers, all re-checked **immediately before deletion** rather than at scan time, because a report can be minutes old:

1. **Marked safe by the scanner.** `~/.claude/projects` (session transcripts) and `node_modules` do not even get a button.
2. **Path sandbox.** Only inside `DerivedData`, `~/.claude`, known caches, and session scratchpads. Verified against traversal: `~/.claude/../../../etc/passwd` normalises to `/etc/passwd` and falls outside every allowed root.
3. **Symlinks rejected**, so the target of a link is never removed in place of the link.
4. **Dead artifacts re-verified.** A project can come back — an unmounted disk, a restored repo, a switched worktree.

**Trash by default**, not `rm`. On the same volume that is a rename, so it is instant even for 12 GB, and reversible in one click. Permanent deletion lives in a separate menu so it cannot be hit by accident. The cost of using the Trash is stated on the confirmation screen: space returns only once it is emptied.

### The fifth barrier, which was not in the plan

While this module was being written, the scratchpad directory contained a session folder modified **37 minutes earlier** — that is, a running one. "Clean up scratchpads, those sessions finished long ago" would have deleted the working directory out from under active work.

So only subdirectories untouched for 24 hours are removed, and the button promises what will actually disappear:

```
× session scratchpads      6 MB
    456 MB skipped — sessions touched in the last 24 h
```

`stray --clean` performs a dry run and deletes nothing. Deletion exists only in the GUI, where the confirmation screen is: a tool that removes gigabytes behind a single terminal flag will eventually do it to someone by accident.

---

## Install

No release build is published yet. Build from source:

```bash
git clone https://github.com/rektor-jg/stray-macos-app
cd stray-macos-app
./scripts/bundle.sh release
open build/Stray.app
```

Requires macOS 14+ and a Swift 6 toolchain (Xcode 16+).

### Command line

The same data as each tab, without the GUI:

```bash
Stray --scan        # Processes tab
Stray --footprint   # Overview tab: what AI is costing you
Stray --disk        # Disk tab
Stray --clean       # dry run: what a cleanup would remove (deletes nothing)
```

### Tests

```bash
swift test          # 50 tests, ~0.5 s
```

---

## Privacy and permissions

- **No network.** No `URLSession`, no sockets, no telemetry. `nm -u` on the built binary shows zero networking symbols, and a test enforces it.
- **No root, no sandbox.** Everything works on processes owned by the current user via `libproc`. No password prompts, no privileged helper. App Store distribution is therefore impossible — its sandbox blocks reading other processes, which is the entire function of the app.
- **Secrets are masked** before anything is copied to the clipboard, shown in the UI, or written to disk. Command lines routinely contain API keys. 24 token prefixes and 20 parameter names, in both `=` and space-separated forms.
- **No subprocess injection.** The three external tools invoked (`du`, `sample`) are called with absolute paths and argument arrays. No shell is involved anywhere.

---

## Language

English and Polish. There is no language switcher, because macOS picks from the user's preferred-language list on its own; English is the base localization. An override lives in the `⋯` menu for anyone who wants to force it.

---

## Status

Working, in daily use on the machine it was written on. Not yet signed for distribution.

| | |
|---|---|
| Detectors | Stuck, Orphan, Leak — implemented |
| Disk layer | dead artifacts, caches, `node_modules` — implemented |
| Deletion | per item and in bulk, Trash by default — implemented |
| Signed release | needs a Developer ID certificate — see [`docs/DYSTRYBUCJA.md`](docs/DYSTRYBUCJA.md) |
| Planned | duplicate dev-server herds, dead ports by traffic rather than connection count, disk-write burn |

### Non-goals

- Not a general system monitor — Stats and iStat Menus do that well.
- Not a throttler — App Tamer does that.
- macOS only. `libproc` is not a portable API.
- Never kills or deletes anything automatically. Every destructive action is one human click.
- No account, no cloud, no subscription.

---

## Documentation

The design notes are in Polish, written as the project was built:

- [`docs/PROJEKT.md`](docs/PROJEKT.md) — full design: detectors, thresholds, false-alarm handling, UI, architecture decisions, and what each round of testing against a live system changed
- [`docs/case-study-2026-08-18.md`](docs/case-study-2026-08-18.md) — the original incident with raw commands and output
- [`docs/DYSTRYBUCJA.md`](docs/DYSTRYBUCJA.md) — signing, notarization, and why the App Store is out

---

## License

MIT.
