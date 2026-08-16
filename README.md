<div align="center">

# drive-sync

**Near-realtime, bidirectional Google Drive sync for Windows — built on [rclone](https://rclone.org).**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6?logo=windows)](https://github.com/danielfrey63/drive-sync)
[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![Built on rclone](https://img.shields.io/badge/built%20on-rclone-3F79AD)](https://github.com/rclone/rclone)

Local changes reach the cloud in **under a minute**, cloud changes land locally in **1–2 minutes**, and a nightly `rclone bisync` guarantees full reconciliation — battle-tested on a corpus of **1.6 million files (61 GiB)** that Google's own DriveFS client could no longer handle.

[How it works](#how-it-works) •
[Quick start](#quick-start) •
[Configuration](#configuration) •
[Operations](#operations-and-monitoring) •
[rclone upstream](#relation-to-rclone-upstream)

</div>

---

```text
$ pwsh -File sync-status.ps1
Last run:     2026-08-06 04:00:01  exit=0  27.9 min
Last success: 2026-08-06 04:28:32  (9.8 h ago)
Watcher up:   running (PID 38248)  lastFlush=2026-08-06 15:56:53  up=412 ren=17 del=9
Watcher down: running (PID 28568)  lastFlush=2026-08-06 15:57:35  down=163 recycled=4
```

## Goals

drive-sync is a set of cooperating PowerShell scripts around rclone. In order of importance, it strives to be:

1. **Safe from data loss.** Nothing is ever hard-deleted: deletions go to the Drive trash (30 days) or the Windows recycle bin. Reactive deletes are capped per cycle, uploads never overwrite newer cloud versions (`--update`), and delete storms are deferred to the nightly reconciliation.
2. **Self-healing.** A watchdog restarts silently died watchers, a start-up catch-up uploads everything modified while no watcher was alive, and the nightly full `bisync` reconciles whatever the reactive layer missed — the worst case is always bounded.
3. **Invisible.** Watchers run as windowless scheduled tasks (no console flashing), survive battery operation and reboots, and need zero interaction.
4. **Honest about its dependencies.** A stock rclone release works out of the box; pending rclone features are detected at runtime and used only when available.

## How it works

```mermaid
flowchart LR
    L[("Local root<br>D:\Meine Ablage")]
    C[("Google Drive<br>gdrive:")]
    W1["watch-drive.ps1<br>FileSystemWatcher<br>~20-40 s"]
    W2["watch-cloud.ps1<br>Changes API poll<br>~1-2 min"]
    B["sync-drive.ps1<br>nightly rclone bisync<br>full reconciliation"]
    L -- "new / update / rename / delete" --> W1 -- "copy · moveto · trash" --> C
    C -- "changes.list delta" --> W2 -- "copy · recycle bin" --> L
    L -. "04:00 safety net" .- B
    B -. "full reconciliation" .- C
```

Three tiers, each covering the blind spots of the one above:

1. **Upload watcher** (`watch-drive.ps1`): a `FileSystemWatcher` batches local events (debounce 15 s / 60 s), uploads via `rclone copy --files-from --no-traverse` (no tree listing), turns renames into server-side `rclone moveto` and verified deletes into Drive-trash moves. On start, a catch-up (`rclone copy --max-age` since the last liveness stamp) closes any coverage gap.
2. **Cloud watcher** (`watch-cloud.ps1`): polls the Drive Changes API with a persisted page token (cheap delta calls, no listing), downloads changed files and moves cloud-trashed files to the recycle bin. A ledger of recent own uploads suppresses echo downloads.
3. **Nightly bisync** (`sync-drive.ps1`, default 04:00): full `rclone bisync` as the guarantee layer — conflicts, cloud-side folder renames, anything missed. Watchers defer their flushes while it runs. Every `EmptyDirCleanupDays` a successful run also prunes empty folder skeletons on the remote (`rclone rmdirs` — bisync only tracks files and never sees directories without any).

### Known limitations

- Windows-only by design (FileSystemWatcher, Task Scheduler, recycle bin).
- Deletes/renames that happen while no watcher runs are only reconciled by the nightly bisync.
- Google-native files (Docs/Sheets/Slides) stay cloud-only (`--drive-skip-gdocs`).

## Quick start

**Requirements:** Windows 10/11, [PowerShell 7](https://github.com/PowerShell/PowerShell) (`scoop install pwsh`), [rclone](https://rclone.org) (`scoop install rclone`), and your own Google OAuth client id (see [howto-google-oauth.md](howto-google-oauth.md) — the shared rclone default id is heavily rate-limited).

```powershell
# 1. rclone remote (type drive, scope drive, your client id/secret)
rclone config              # create remote "gdrive"; then: rclone lsd gdrive:

# 2. adjust config.local.ps1 (copy from config.local.ps1.example) and filters.txt

# 3. one-time baseline - reconciles both sides completely, can take hours
pwsh -File sync-drive.ps1 -Resync

# 4. register the scheduled tasks (nightly bisync + watchers + watchdog)
pwsh -File install-sync-task.ps1
pwsh -File install-watcher-task.ps1

# 5. check
pwsh -File sync-status.ps1
```

All installers are idempotent: re-running updates task definitions without disturbing running watchers.

## Configuration

Defaults live in [`config.ps1`](config.ps1); machine-specific overrides go into `config.local.ps1` (gitignored, see the [example](config.local.ps1.example)).

| Key | Meaning | Default |
| --- | --- | --- |
| `LocalRoot` | local mirror root | `D:\Meine Ablage` |
| `RemoteName` | rclone remote name | `gdrive` |
| `StateDir` | runtime state (logs, locks, cursors) | `%LOCALAPPDATA%\drive-sync` |
| `MaxDeletes` | reactive delete cap per flush; larger storms go to the nightly bisync | `50` |
| `PollSeconds` | Changes API poll interval | `60` |
| `BisyncDailyAt` | daily start time of the reconciliation bisync (`HH:mm`) | `04:00` |
| `EmptyDirCleanupDays` | days between remote empty-dir cleanups (`rclone rmdirs` after a successful bisync); `0` disables | `30` |
| `EmptyDirCleanupExcludes` | paths the cleanup skips (folders whose only content is an unexportable google-native file would look empty) | `/Google Earth/**` |
| `PacerMinSleep` / `PacerBurst` | Drive pacer tuning (safe with an own client id) | `10ms` / `200` |

Include/exclude rules live in [`filters.txt`](filters.txt) — changing them requires a one-time `sync-drive.ps1 -Resync`.

## Operations and monitoring

`pwsh -File sync-status.ps1` shows the last bisync, watcher liveness (from the PID locks) and transfer counters. All runtime state lives in the configured `StateDir`.

<details>
<summary><b>State files reference</b></summary>

| Path | Content |
| --- | --- |
| `status.json` | last and last successful bisync run |
| `logs\bisync-*.log` | one log per bisync run, newest 30 kept |
| `watcher.log`, `cloud-watcher.log` | watcher logs (rotated), incl. 10-min heartbeats |
| `watcher.lock`, `cloud-watcher.lock`, `sync.lock` | PID locks (single instance / bisync precedence) |
| `watcher-status.json`, `cloud-watcher-status.json` | counters for `sync-status.ps1` |
| `cloud-watcher-pagetoken.txt` | persisted Changes API cursor; deleting it restarts from "now" (the gap is closed by the next bisync) |
| `upload-ledger.txt` | echo control: own uploads of the last 30 min |
| `rmdirs-last.txt` | timestamp of the last remote empty-dir cleanup |
| `watcher-lastseen.txt`, `watcher-catchup.log` | liveness stamp of the upload watcher ("everything up to here is uploaded or captured" — only advances while nothing is pending) and the log of the last start-up catch-up |
| `watchdog.log`, `watchdog-pause` | watchdog log; the pause marker suppresses restarts during maintenance (auto-discarded after 6 h; a first line `pid:<n>` keeps it alive as long as that process runs) |
| `bin\rclone.exe` | optional custom rclone build; the watchers prefer it, deleting it falls back to the PATH rclone |

</details>

<details>
<summary><b>Manual task setup (without the installer scripts)</b></summary>

The four tasks can also be created by hand in Task Scheduler (`taskschd.msc`), as the logged-on user, "Run only when user is logged on":

| Task | Trigger | Action | Settings |
| --- | --- | --- | --- |
| `DriveSync watcher` | At log on | `wscript.exe` with arguments `//B //Nologo "<repo>\run-hidden.vbs" "<path>\pwsh.exe" -NoProfile -File "<repo>\watch-drive.ps1"` | no time limit; do not start a new instance if one is running |
| `DriveSync cloud watcher` | At log on | as above, with `watch-cloud.ps1` | as above |
| `DriveSync watchdog` | Once, then repeat every 15 min | as above, with `watchdog.ps1` | time limit 5 min; run as soon as possible after a missed start |
| `DriveSync rclone bisync` | Daily 04:00 | `pwsh.exe` with arguments `-NoProfile -WindowStyle Hidden -File "<repo>\sync-drive.ps1"` | time limit 6 h; only on network; run missed starts when available |

Two hard-won details:

- The `wscript.exe` + `run-hidden.vbs` detour exists because `pwsh -WindowStyle Hidden` still flashes a console window on start. The bisync task deliberately runs **without** the wrapper: only a directly launched process can be killed by its 6 h execution time limit.
- For all four tasks, disable **"Start the task only if the computer is on AC power"** and **"Stop if the computer switches to battery power"**. The PowerShell `New-ScheduledTaskSettingsSet` defaults are silently restrictive — with them, pulling the power cord kills the watchers and task starts on battery hang in the queue.

</details>

<details>
<summary><b>Uninstall</b></summary>

Scripted: `pwsh -File uninstall.ps1` stops both watcher processes and removes all four tasks; `-RemoveState` also deletes the state directory. Manually:

1. Stop the watcher processes: PIDs are in `watcher.lock` and `cloud-watcher.lock` inside the state dir (`Stop-Process -Id <pid>`). If a bisync is running (PID in `sync.lock` alive), let it finish first.
2. Delete the four tasks: `schtasks /Delete /F /TN "DriveSync watcher"` etc. (or in `taskschd.msc`).
3. Optionally delete the state: `Remove-Item -Recurse -Force "$env:LOCALAPPDATA\drive-sync"`.
4. Optionally remove the rclone remote (`rclone config delete gdrive`) and revoke the OAuth access in your Google account.

Uninstalling never touches your data: the local mirror and the cloud content stay untouched, only the synchronisation ends.

</details>

## Relation to rclone upstream

Everything here rides on [rclone](https://github.com/rclone/rclone) (`bisync`, `copy`, `moveto`, the Drive backend). Building this produced three upstream contributions, currently in flight:

| Contribution | What it does | Used here for |
| --- | --- | --- |
| [PR #9598](https://github.com/rclone/rclone/pull/9598) — `--files-from-strict` (review + testing) | `copy --files-from` fails loudly on missing paths instead of skipping silently | upload batches fail and retry instead of dropping files |
| [Issue #9737](https://github.com/rclone/rclone/issues/9737) / [PR #9741](https://github.com/rclone/rclone/pull/9741) — `--local-use-trash` | local backend deletes to the Windows recycle bin (or freedesktop/macOS trash) | cloud-trash propagation, with a Win32 `SHFileOperation` fallback |
| [Issue #9738](https://github.com/rclone/rclone/issues/9738) — `rclone changes` | first-class change-polling command | would replace most of the custom Changes API code in `watch-cloud.ps1` |

Both watchers detect these flags at runtime and degrade gracefully, so a **stock rclone release works out of the box**. To use the pending features today, build rclone from a branch containing the backports and drop the binary at `<StateDir>\bin\rclone.exe` — the watchers prefer it automatically.

## Background

drive-sync replaced Google's official DriveFS client after it repeatedly failed on this corpus: runaway RAM (11+ GB), a wedged virtual drive that blocked every PowerShell start, and rebuild loops progressing at ~500 items/hour over 2.5 million cloud items. Two full state resets later the pattern was clear — DriveFS does not scale to this corpus. The migration notes live in [HANDOVER-2026-07-30-drivefs-rclone.md](HANDOVER-2026-07-30-drivefs-rclone.md); `analyze-corpus.ps1`, `move-ablage-repos.ps1` and `purge-cloud-moved.ps1` are one-off utilities from that migration, kept for reference.

## Components

| File | Purpose |
| --- | --- |
| `config.ps1` | central configuration (defaults); override per machine via `config.local.ps1` |
| `sync-drive.ps1` | bisync wrapper (lock, logs, `status.json`); `-Resync` re-baselines, `-DryRun` previews |
| `watch-drive.ps1` | upload watcher local → cloud (new/update/rename/delete + start-up catch-up) |
| `watch-cloud.ps1` | download watcher cloud → local (new/update/trash); `-Once` runs a single cycle |
| `watchdog.ps1` | restarts silently died watchers every 15 min |
| `filter-rules.ps1` | shared exclude logic for the watchers, derived from `filters.txt` |
| `run-hidden.vbs` | windowless task launcher (no console window flashing) |
| `install-sync-task.ps1`, `install-watcher-task.ps1` | register the scheduled tasks (idempotent) |
| `uninstall.ps1` | stops the watchers and removes all four tasks (`-RemoveState` also deletes the state dir) |
| `sync-status.ps1` | status overview (last bisync, watcher liveness and counters) |
| `howto-google-oauth.md` | how to create your own Google OAuth client id |

## License

[MIT](LICENSE)
