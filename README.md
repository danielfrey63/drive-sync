# drive-sync

Near-realtime bidirectional Google Drive sync for Windows, built on [rclone](https://rclone.org). A set of PowerShell scripts that replaced Google's official DriveFS client after it repeatedly failed to handle a ~1.6 million file corpus (runaway RAM, wedged virtual drive, endless re-sync loops).

Three cooperating tiers:

1. **Nightly bisync** (daily, default 04:00): `sync-drive.ps1` runs a full `rclone bisync` as the safety net for everything the watchers do not cover (conflicts, cloud-side folder renames, missed events). A full run lists the whole tree on both sides.
2. **Upload watcher** (`watch-drive.ps1`, permanent): a `FileSystemWatcher` on the local root uploads new/changed files after ~20–40 s, propagates renames server-side (`rclone moveto`) and verified local deletes into the **Drive trash** (capped per flush). On start, a catch-up (`rclone copy --max-age` over the time since the last liveness stamp) uploads files created while no watcher was running.
3. **Cloud watcher** (`watch-cloud.ps1`, permanent): polls the Google Drive Changes API (delta calls with a persisted page token, no tree listing), downloads new/changed cloud files after ~1–2 min and moves cloud-trashed files to the **Windows recycle bin** (capped). A ledger of recent own uploads suppresses echo downloads.

Guiding principle: **nothing is ever hard-deleted** — deletions always end up in the Drive trash (30 days) or the Windows recycle bin.

## Components

| File | Purpose |
| --- | --- |
| `config.ps1` | central configuration (defaults); override per machine via `config.local.ps1` (gitignored) |
| `sync-drive.ps1` | bisync wrapper (lock, logs, `status.json`); `-Resync` re-baselines, `-DryRun` previews |
| `watch-drive.ps1` | upload watcher local → cloud (new/update/rename/delete + start-up catch-up) |
| `watch-cloud.ps1` | download watcher cloud → local (new/update/trash); `-Once` runs a single cycle |
| `watchdog.ps1` | restarts silently died watchers every 15 min |
| `filter-rules.ps1` | shared exclude logic for the watchers, derived from `filters.txt` |
| `filters.txt` | include/exclude rules for bisync and watchers (changes require a `-Resync`!) |
| `run-hidden.vbs` | windowless task launcher (no console window flashing) |
| `install-sync-task.ps1` | registers the nightly bisync task |
| `install-watcher-task.ps1` | registers watcher and watchdog tasks |
| `uninstall.ps1` | stops the watchers and removes all four tasks (`-RemoveState` also deletes the state dir) |
| `sync-status.ps1` | status overview (last bisync, watcher liveness and counters) |
| `howto-google-oauth.md` | how to create your own Google OAuth client id |

`analyze-corpus.ps1`, `move-ablage-repos.ps1`, `purge-cloud-moved.ps1` and the `*.md` handover notes are one-off utilities from the original DriveFS migration, kept for reference.

## Requirements

- Windows 10/11, PowerShell 7 (`scoop install pwsh`), rclone (`scoop install rclone`).
- Your own Google OAuth client id (see `howto-google-oauth.md`) — the shared rclone default id is heavily rate-limited. The downloaded `client_secret_*.json` stays next to the scripts and is gitignored — **never commit it**.
- An rclone remote for your Drive (default name `gdrive`, type `drive`, scope `drive`, client id/secret from the JSON): run `rclone config`; `rclone lsd gdrive:` must work.

## Configuration

Defaults live in `config.ps1`. For machine-specific values, copy `config.local.ps1.example` to `config.local.ps1` (gitignored) and override what differs:

| Key | Meaning | Default |
| --- | --- | --- |
| `LocalRoot` | local mirror root | `D:\Meine Ablage` |
| `RemoteName` | rclone remote name | `gdrive` |
| `StateDir` | runtime state (logs, locks, cursors) | `%LOCALAPPDATA%\drive-sync` |
| `MaxDeletes` | reactive delete cap per flush; larger storms go to the nightly bisync | `50` |
| `PollSeconds` | Changes API poll interval | `60` |
| `PacerMinSleep` / `PacerBurst` | Drive pacer tuning (safe with an own client id) | `10ms` / `200` |

## Installation

1. Meet the requirements above and adjust `config.local.ps1` and `filters.txt` for your corpus.
2. Create the baseline: `pwsh -File sync-drive.ps1 -Resync` — the first run reconciles both sides completely and can take hours.
3. `pwsh -File install-sync-task.ps1` — registers the daily bisync (default 04:00, change via `-DailyAt "HH:mm"`).
4. `pwsh -File install-watcher-task.ps1` — registers and starts both watchers plus the watchdog.
5. Check: `pwsh -File sync-status.ps1`.

All installers are idempotent: re-running updates the task definitions without disturbing running watchers (live instances are detected via their PID locks).

### Manual task setup (without the installer scripts)

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

## Operations and monitoring

All runtime state lives in the configured `StateDir` (default `%LOCALAPPDATA%\drive-sync\`):

| Path | Content |
| --- | --- |
| `status.json` | last and last successful bisync run |
| `logs\bisync-*.log` | one log per bisync run, newest 30 kept |
| `watcher.log`, `cloud-watcher.log` | watcher logs (rotated at size limits), incl. 10-min heartbeats |
| `watcher.lock`, `cloud-watcher.lock`, `sync.lock` | PID locks (single instance / bisync precedence) |
| `watcher-status.json`, `cloud-watcher-status.json` | counters for `sync-status.ps1` |
| `cloud-watcher-pagetoken.txt` | persisted Changes API cursor; deleting it restarts from "now" (the gap is closed by the next bisync) |
| `upload-ledger.txt` | echo control: own uploads of the last 30 min |
| `watcher-lastseen.txt`, `watcher-catchup.log` | liveness stamp of the upload watcher ("everything up to here is uploaded or captured" — only advances while nothing is pending) and the log of the last start-up catch-up |
| `watchdog.log`, `watchdog-pause` | watchdog log; the `watchdog-pause` marker suppresses restarts during maintenance (auto-discarded after 6 h; a first line `pid:<n>` keeps the pause alive as long as that process runs) |
| `bin\rclone.exe` | optional custom rclone build; the watchers prefer it, deleting it falls back to the PATH rclone |

Useful moves: `pwsh -File sync-status.ps1` for the overall picture; `pwsh -File sync-drive.ps1` for a manual bisync; for maintenance set `Set-Content "$env:LOCALAPPDATA\drive-sync\watchdog-pause" "reason"` (or `pid:<n>` as first line) and remove it afterwards.

## Relation to rclone upstream

Everything here rides on [rclone](https://github.com/rclone/rclone) (`bisync`, `copy`, `moveto`, the Drive backend). Building this produced three upstream contributions, currently in flight:

- **[PR #9598](https://github.com/rclone/rclone/pull/9598) — `--files-from-strict`** (review + testing contributed): makes `copy --files-from` fail loudly when a listed path is missing instead of skipping it silently. The upload watcher uses the flag when available — a stale path mapping then fails the batch and triggers a retry instead of dropping files.
- **[Issue #9737](https://github.com/rclone/rclone/issues/9737) / [PR #9741](https://github.com/rclone/rclone/pull/9741) — `--local-use-trash`**: teaches the local backend to move deletions to the Windows recycle bin (or freedesktop/macOS trash) instead of hard-deleting. The cloud watcher uses it for cloud-trash propagation when available, with a Win32 `SHFileOperation` fallback otherwise.
- **[Issue #9738](https://github.com/rclone/rclone/issues/9738) — `rclone changes`**: proposal for a first-class change-polling command; if it lands, it replaces most of the custom Changes API code in `watch-cloud.ps1`.

Both watchers detect these flags at runtime and degrade gracefully, so a **stock rclone release works out of the box**. To use the pending features today, build rclone from a branch containing the backports and drop the binary at `<StateDir>\bin\rclone.exe` — the watchers prefer it automatically; deleting it falls back to the PATH rclone.

## Uninstall

Scripted: `pwsh -File uninstall.ps1` stops both watcher processes and removes all four tasks; `-RemoveState` also deletes the state directory.

Manually, that corresponds to:

1. Stop the watcher processes: PIDs are in `watcher.lock` and `cloud-watcher.lock` inside the state dir (`Stop-Process -Id <pid>`). If a bisync is running (PID in `sync.lock` alive), let it finish first.
2. Delete the four tasks: `schtasks /Delete /F /TN "DriveSync watcher"` etc. (or in `taskschd.msc`).
3. Optionally delete the state: `Remove-Item -Recurse -Force "$env:LOCALAPPDATA\drive-sync"`.
4. Optionally remove the rclone remote (`rclone config delete gdrive`) and revoke the OAuth access in your Google account.

Uninstalling never touches your data: the local mirror and the cloud content stay untouched, only the synchronisation ends.

## License

MIT — see [LICENSE](LICENSE).
