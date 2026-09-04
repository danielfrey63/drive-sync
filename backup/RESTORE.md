# Recovery runbook

Read this **before** you need it, once. In an emergency, jump to the scenario and follow it top to bottom — every scenario is self-contained and starts with the thing that must not wait.

Scenarios, from harmless to bad:

1. [A file or folder was deleted or overwritten](#1-a-file-or-folder-was-deleted-or-overwritten)
2. [I need an older version of a file](#2-i-need-an-older-version-of-a-file)
3. [D: is gone (disk failure)](#3-d-is-gone-disk-failure)
4. [The whole machine is gone](#4-the-whole-machine-is-gone)
5. [Ransomware](#5-ransomware)
6. [Restore drill (do this quarterly)](#6-restore-drill-do-this-quarterly)
7. [Secrets drill (from a second machine)](#7-secrets-drill-from-a-second-machine)

Then: [Prerequisites](#prerequisites-every-scenario-needs-these), [What the backup does not contain](#what-the-backup-does-not-contain), [Set up now, not later](#set-up-now-not-later).

---

## Prerequisites (every scenario needs these)

Three secrets, and the recovery is only as good as the weakest of them. All three must exist **outside** this machine — in the password manager, on a phone, on paper:

| Secret | Where it lives | If lost |
| --- | --- | --- |
| **restic repository password** | `%LOCALAPPDATA%\restic\storagebox-password.txt` + password manager | backup is gone. No support, no reset, no brute force. |
| **Storage Box login** (`uXXXXXX` + password) | Hetzner Console, password manager | reset in the Console → Storage Box → *Reset password* |
| **Hetzner account** (login + 2FA) | password manager | Hetzner account recovery |

The SSH key is *not* on that list: it is convenient, not essential. Password login on port 23 works as long as SSH-Support is enabled, and a new key can be installed from any machine (see [scenario 4](#4-the-whole-machine-is-gone)).

Every restic call below assumes this shell prelude. `<you>` is the Windows user name, `-o $o` must be on every command:

```powershell
$env:RESTIC_REPOSITORY = "sftp:storagebox:/home/restic"
$env:RESTIC_PASSWORD_FILE = "$env:LOCALAPPDATA\restic\storagebox-password.txt"
$o = "sftp.command=C:/Users/<you>/scoop/apps/openssh/current/ssh.exe storagebox -s sftp"
```

Repository paths are written `/C/Users/...` and `/D/Meine Ablage/...`. `restic restore` rebuilds that layout under `--target`, so a restore of `/D/Meine Ablage/X` to `--target D:\restore` lands in `D:\restore\D\Meine Ablage\X`. Restore into a **staging directory first**, look, then move — never straight over the live tree.

---

## 1. A file or folder was deleted or overwritten

**First:** if the file lived under `D:\Meine Ablage`, check the two cheaper places before touching restic — the Windows recycle bin (the cloud watcher moves cloud-side deletions there) and the [Google Drive trash](https://drive.google.com/drive/trash) (the upload watcher moves local deletions there, 30 days). Both are faster and keep Drive file ids intact.

Otherwise:

```powershell
# 1. find it — which snapshots contain it, and when did it last change
restic find -o $o "*Angebot 2026*"                 # glob on the file name, all snapshots
restic find -o $o --newest "2026-08-28 18:00" "*.docx"   # narrow by modification time

# 2. take the newest snapshot that still has the good version
restic snapshots -o $o --compact                   # pick the id, snapshots are every 6 h

# 3. restore into staging
restic restore <id> -o $o --target "D:\restore" --include "/D/Meine Ablage/Akros/Kunden/X/Angebot 2026.docx" --verify

# 4. check, then move into place
Get-ChildItem "D:\restore" -Recurse -File
Move-Item "D:\restore\D\Meine Ablage\Akros\Kunden\X\Angebot 2026.docx" "D:\Meine Ablage\Akros\Kunden\X\"
```

`--include` takes the repository path (forward slashes, drive letter as first component) and accepts globs: `--include "/D/Meine Ablage/Akros/Kunden/X/**"` restores a whole folder. `--verify` re-reads every restored file against its stored hash.

For a single small file, `dump` writes it straight to a path without the directory scaffolding:

```powershell
restic dump <id> -o $o "/D/Meine Ablage/Akros/Kunden/X/Angebot 2026.docx" > "D:\restore\Angebot 2026.docx"
```

Moving the file back under `D:\Meine Ablage` is enough — the upload watcher pushes it to the cloud within a minute.

## 2. I need an older version of a file

Same tools, different question — *which* snapshot. `diff` shows what changed between two snapshots, restricted to a subtree if you like; `find` with `-s` lists the versions across snapshots:

```powershell
restic snapshots -o $o --compact --latest 30       # ids and times of the last 30 snapshots
restic diff <older-id> <newer-id> -o $o | Select-String "Kunden/X/"
restic ls <id> -o $o -l "/D/Meine Ablage/Akros/Kunden/X"   # size and mtime as stored in that snapshot
```

Retention keeps every 6-hourly state for a week, then one per day for a month, then one per month. A version that existed for less than six hours between two snapshots was never captured; a version older than a week only survives if it was the last one of that day.

Then restore as in scenario 1 with the chosen `<id>`.

## 3. D: is gone (disk failure)

**First:** stop the sync before the new disk is mounted. Otherwise the upload watcher sees an empty `D:\Meine Ablage`, and while its delete cap (50 per flush) prevents a wipe, the nightly bisync would report a "Path1 missing" critical abort and every restart of the watchers generates noise you do not want while restoring.

```powershell
pwsh -File uninstall.ps1       # stops watchers, removes the sync tasks; state dir stays
```

Then decide where to restore **from** — for `D:\Meine Ablage` there are two sources, and the cloud is usually the better one:

| Source | When | How |
| --- | --- | --- |
| **Google Drive** (the mirror) | the cloud is intact — a disk failure does not touch it | replace the disk, mount it as `D:`, then `pwsh -File sync-drive.ps1 -Resync`. This is the baseline procedure from the main README; expect hours (1.6 M files). Google-native docs stay cloud-only as always. Drive file ids, sharing and version history are untouched. |
| **restic** | the cloud is damaged too (ransomware, mass deletion synced up, account lost) or Drive is unreachable | see below |

Restore from restic:

```powershell
# staging on the new disk, verify, then rename — no half-restored tree ever carries the live name
restic restore latest -o $o --target "D:\restore" --include "/D/Meine Ablage/**" --verify
Rename-Item "D:\restore\D\Meine Ablage" "D:\Meine Ablage" ; Move-Item "D:\Meine Ablage" "D:\"
```

`latest` picks the newest snapshot; give an explicit `<id>` if the newest is not the one you want. A 1.7 TB restore over a home downlink takes a day or more; `restore` is resumable — rerun the same command, `--overwrite if-changed` (or the default) skips files that are already correct.

Not in the backup and therefore not restored: everything in `restic-excludes.txt` — for D: that is `node_modules`, `.venv`, build outputs, `CVS`/`.svn`, `.metadata`. Git working trees come back complete including `.git`; run `npm install` / `uv sync` per project as needed.

**Afterwards:** re-register the sync (`install-sync-task.ps1`, `install-watcher-task.ps1`) and run `sync-drive.ps1 -Resync` once so the bisync gets a fresh baseline. Resync *unions* both sides — if the cloud still holds files that should not exist (scenario 5), clean the cloud first.

## 4. The whole machine is gone

Theft, fire, dead SSD, or the [ransomware](#5-ransomware) scenario after the decision to rebuild. The order is: secrets → tools → access → verify → restore data → restore profile → sync.

1. **Secrets** from the password manager: restic repository password, Storage Box `uXXXXXX` and password, Hetzner login.

2. **Windows and tools** on the new machine:

   ```powershell
   # scoop, then
   scoop install pwsh git restic openssh
   ```

   `openssh` from scoop is the Microsoft build (10.x): post-quantum KEX **and** access to the Windows `ssh-agent` service. The `ssh` that ships with Windows (9.5) has no PQ key exchange; the one from `git-with-openssh` cannot reach the agent. `C:\Users\<you>\scoop\apps\openssh\current\ssh.exe` is the one to pin.

3. **New SSH key, installed via password login.** The old key is on the lost machine; treat it as compromised. The box keeps its `authorized_keys` in `/home/.ssh/`, reachable over SFTP:

   ```powershell
   ssh-keygen -t ed25519 -a 100 -C "hetzner-storagebox" -f "$env:USERPROFILE\.ssh\openssh\hetzner_sb"
   $ms = "$env:USERPROFILE\scoop\apps\openssh\current"
   # password prompt — the Storage Box password from the password manager
   Get-Content "$env:USERPROFILE\.ssh\openssh\hetzner_sb.pub" | & "$ms\ssh.exe" -p 23 uXXXXXX@uXXXXXX.your-storagebox.de install-ssh-key
   ```

   If `install-ssh-key` is not available on the box, upload the key by hand: `sftp -P 23 uXXXXXX@uXXXXXX.your-storagebox.de`, then `put hetzner_sb.pub .ssh/authorized_keys` (this **replaces** the file — exactly what you want, the old key must go). Port 22 needs the RFC4716 format (`ssh-keygen -e -f hetzner_sb.pub`); port 23 takes the one-line format. Both may sit in the same file.

   Then the `Host storagebox` block in `~/.ssh/config`, `known_hosts` and `ssh-add` as in the README's *One-time setup* steps 3–5. Compare the host key fingerprint with the Console — you are typing a password into this connection.

4. **Repository password file**, then **verify before restoring anything**:

   ```powershell
   New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\restic" | Out-Null
   Set-Content "$env:LOCALAPPDATA\restic\storagebox-password.txt" -Value "<password from the manager>" -NoNewline
   icacls "$env:LOCALAPPDATA\restic\storagebox-password.txt" /inheritance:r /grant:r "$($env:USERNAME):R"
   restic snapshots -o $o --compact          # lists snapshots = password and access are right
   restic check -o $o                        # structure check, minutes; add --read-data-subset=5% for a data sample
   ```

5. **Restore D:** as in [scenario 3](#3-d-is-gone-disk-failure) — cloud first if intact, restic otherwise.

6. **Restore the user profile selectively.** Do **not** restore `/C/Users/<you>/**` over a freshly created profile: `AppData` contains per-machine state (registry-bound app installs, credential caches, `NTUSER.DAT` is excluded anyway) and a wholesale copy leaves you with a half-broken profile. Restore to staging and pull over what you actually need:

   ```powershell
   restic restore latest -o $o --target "D:\restore" --include "/C/Users/<you>/**" --verify
   ```

   Then, from `D:\restore\C\Users\<you>\`:

   | Take | Leave / reinstall |
   | --- | --- |
   | `Documents`, `Pictures`, `Videos`, `Desktop`, `Downloads` — move as a whole | `AppData\Local\Microsoft\*` — Windows recreates it |
   | `.ssh` (except the compromised `hetzner_sb`, already replaced), `.gitconfig`, `.config`, `.claude` | `AppData\Local\Programs\*` — was excluded; reinstall |
   | `AppData\Roaming\Code\User` (VS Code settings/keybindings), `AppData\Roaming\JetBrains` | `scoop\apps` — was excluded; `scoop install` from the app list |
   | `scoop\persist` — after reinstalling the apps, copy the persist folders in to get their data back | `.docker`, `.cache`, `.codeium` — caches |
   | `AppData\Local\Microsoft\Outlook` — PST files matter, OST files are just a cache of the mailbox | browser profiles — sign in again, sync restores them |
   | `AppData\Local\drive-sync` — logs and cursors; the cursors are only useful if the sync was not reset | |

   The Windows ssh-agent, `rclone config` (Google OAuth token), git credentials and every other machine-bound secret must be re-created; nothing of that is portable by design.

7. **Sync:** clone this repository from `D:\Meine Ablage\Develop\danielfrey63\drive-sync` (it is part of the restored tree — or from the `github`/`origin` remote), `rclone config` with the Google client id, `sync-drive.ps1 -Resync`, install the tasks. Then `backup\install-backup-task.ps1` from an elevated shell — the new machine backs up into the **same** repository, deduplicated against everything already there.

8. **Rotate** what the lost machine knew: the Storage Box password (Console), the restic repository password (`restic key add`, then `restic key remove <old-id>` — the master key stays, the old password stops working), the Google OAuth token (revoke in the Google account), git and any other stored credentials.

## 5. Ransomware

The upload watcher pushes local changes to the cloud within a minute, so by the time you notice, the encrypted files **are already in Google Drive**. The restic repository is the only copy that ransomware on this machine cannot rewrite in place — but it *can* delete it, because the machine holds the key and the repository password. Speed matters on exactly one step: freezing the repository.

### Essential steps, in this order

**A. Cut the machine off — first, before anything else.** Pull the network cable, switch Wi-Fi off, or pull the plug. Do not log in "to have a look", do not reboot into it, do not connect any external disk to it. Every minute online is another batch of files encrypted and synced up.

**B. From another device (phone is fine), freeze the repository.** Hetzner Console → the Storage Box → **Snapshots → Create snapshot.** A Storage Box snapshot is taken server-side and is read-only over SSH (`.zfs/snapshot`); the key and the restic password on the infected machine cannot touch it. Give it a name with the date. Do this even if you are not sure it is ransomware — a snapshot costs nothing and can be deleted later.

What *can* delete a snapshot is the Hetzner **account**: the Console and the API. If the infected machine had a logged-in Console tab, a saved Hetzner password, an unlocked password manager or an API token on disk, assume the attacker has that too — change the Hetzner password and revoke API tokens from the other device **before** anything else in this step, then create the snapshot. The defence for this is hygiene, set up in advance: 2FA on the Hetzner account, no persistent Console login on the backup machine, no API token stored there, password manager locked when you are not in front of it. Truly immutable storage (a retention lock that not even the account owner can lift) exists only as S3 Object Lock in compliance mode at other providers — a possible second target, not a replacement.

**C. Lock the attacker out of the box.** Still in the Console: **Reset password** (note the new one), and **disable SSH-Support** for now — that closes port 23 for the compromised key, which you cannot revoke from the Console. Also **disable External reachability** if you like; you will re-enable both from the clean machine.

**D. Stop the propagation to the cloud.** Sign in to Google from the other device, [security → your devices](https://myaccount.google.com/device-activity) and [third-party access](https://myaccount.google.com/permissions): revoke the rclone client's access. The watchers on the infected machine (if it is ever reconnected) lose their token. The Drive trash and version history stay as they are — do not "clean up" in Drive yet.

**E. Freeze the evidence, decide about the machine.** The encrypted disks are worth keeping for a while (a decryptor may appear; some families leave the key in memory). Take the disks out or set them aside; **the machine is rebuilt on a fresh disk, not cleaned.** Now you are in [scenario 4](#4-the-whole-machine-is-gone) for the rebuild; come back here for the restore choices.

### Choosing the snapshot

On the clean machine, once `restic snapshots` works: find the last snapshot from **before** the encryption started. Ransomware shows in `diff` as thousands of modified files, usually with a new extension or a ransom note in every folder:

```powershell
restic snapshots -o $o --compact --latest 40
restic diff <earlier> <later> -o $o | Select-Object -First 40     # look for a wall of "M" and "+ *.locked"-style names
restic find -o $o "*README_TO_DECRYPT*" "*.locked" "*.encrypted"  # ransom notes and typical extensions, all snapshots
```

Walk backwards until the diff between two consecutive snapshots looks like an ordinary working day. Snapshots are six hours apart, so you lose at most half a working day — provided the retention had not yet thinned the period. Check that the chosen snapshot passes `restic check --read-data-subset=5%`. If the attacker managed to `forget`/`prune` before step B, the Storage Box snapshot from step B still has the repository as it was at that moment: Console → Snapshots → **Revert** rolls `/home/` back to it (this replaces the live repository — fine, the live one is the damaged one).

### Restoring

Follow scenario 4 for the machine and profile, with the chosen `<id>` instead of `latest`. For `D:\Meine Ablage`:

1. Restore from restic into staging on the new machine, verify, rename into place — **not** from the cloud, the cloud is encrypted too.
2. Clean the cloud **before** the sync sees it. `sync-drive.ps1 -Resync` unions both sides and would pull every encrypted file back down. Instead push the restored state up one-way with rclone, which deletes what does not exist locally:

   ```powershell
   rclone sync "D:\Meine Ablage" gdrive: --filter-from "<repo>\filters.txt" --drive-skip-gdocs --modify-window 1s --dry-run -P   # preview first
   rclone sync "D:\Meine Ablage" gdrive: --filter-from "<repo>\filters.txt" --drive-skip-gdocs --modify-window 1s -P
   ```

   Google-native docs are not touched by this (they are skipped both ways). Ransomware cannot encrypt them either — they are not files on disk — so they survive untouched. Files deleted by this `sync` go to the Drive trash, so even this step is reversible for 30 days.
3. Now `sync-drive.ps1 -Resync` for a clean baseline, then the tasks.

### Afterwards

- Rotate every secret the old machine held (scenario 4, step 8) — plus the Storage Box password again if you set a temporary one, and re-enable SSH-Support and External reachability.
- Keep the Storage Box snapshot from step B until the restored state has run for a few weeks; then delete it, it counts against the box's quota.
- Check the [Drive trash](https://drive.google.com/drive/trash) once for anything the attacker deleted rather than encrypted; restore from there if needed (keeps ids).
- Check the Google account for changed recovery options, added forwarding rules or app passwords — a ransomware operator with a logged-in browser has had access to it.

## 6. Restore drill (do this quarterly)

A backup that was never restored is a hypothesis. Fifteen minutes, no elevation needed:

```powershell
restic snapshots -o $o --compact --latest 5                 # is it running? are the timestamps six hours apart?
restic check -o $o --read-data-subset=1%                    # does the data read back?
restic restore latest -o $o --target "D:\restore" --include "/D/Meine Ablage/Develop/danielfrey63/drive-sync/**" --verify
git -C "D:\restore\D\Meine Ablage\Develop\danielfrey63\drive-sync" status  # a restored git repo must be clean and complete
restic stats -o $o --mode raw-data                          # repository size vs. box quota — plan the upgrade before it is full
Remove-Item "D:\restore" -Recurse -Force
```

Once a year, do scenario 4 for real on a spare machine or a VM: the secrets from the password manager, nothing from this machine. That is the only test of the thing that actually fails in practice — the secret you thought you had saved.

## 7. Secrets drill (from a second machine)

The restore drill in section 6 proves the data is readable **from this machine**. It says nothing about the case that actually happens: the machine is gone and all you have is the password manager. This drill closes that gap and is a dry run of [scenario 4](#4-the-whole-machine-is-gone), steps 1–4.

Rules: use a machine that is not the backup client (a second laptop is ideal, a phone only tests retrieval). Read every value off the password manager and type it — never copy the password file over, never `scp` a key. Copying anything from the backup client tests the client, not the backup.

### Preparation

Two requirements on the drill machine, whatever it runs: restic **≥ 0.14** (older builds cannot read a version-2 repository) and an `ssh` that speaks `sntrup761x25519-sha512@openssh.com`, because the host alias below refuses anything weaker.

**Linux (Ubuntu):**

```bash
sudo apt install restic
restic version    # >= 0.14, ideally >= 0.16 - otherwise take the release binary from github.com/restic/restic
ssh -V            # >= 8.5 has sntrup761x25519; any current Ubuntu is fine
```

**Windows:** do not rely on the bundled `C:\Windows\System32\OpenSSH\ssh.exe` — version 9.5 ships without any post-quantum key exchange (verified 30.08.2026), so the alias will fail to negotiate. Install the Microsoft build and make sure it wins in `PATH`:

```powershell
scoop install restic openssh      # or: winget install restic.restic Microsoft.OpenSSH.Beta
restic version
ssh -Q kex | Select-String "sntrup|mlkem"   # must not be empty
```

Then the host alias, typed by hand into `~/.ssh/config` (Windows: `%USERPROFILE%\.ssh\config`). No `IdentityFile` — authenticating with the password is the whole point:

```
Host storagebox
    HostName uXXXXXX.your-storagebox.de
    User uXXXXXX
    Port 23
    KexAlgorithms sntrup761x25519-sha512@openssh.com
    HostKeyAlgorithms ssh-ed25519
```

### Test A — Storage Box password and host identity

```
ssh storagebox
```

Identical on both platforms. The first connection prints the host key fingerprint; compare it with the one in the Hetzner Console (`SHA256:XqONwb1S0zuj5A1CDxpOSuD2hnAArV1A3wKY7Z3sdgM` at the time of writing) **before** typing yes — you are about to send a password over this connection. Then enter the box password from the password manager. A shell prompt means the stored value is correct; `exit` leaves again.

### Test B — restic repository password

This is the one that cannot be reset or recovered, so it matters most. restic prompts twice: once for SSH, once for the repository.

```bash
restic -r sftp:storagebox:/home/restic snapshots --compact
```

```powershell
restic -r sftp:storagebox:/home/restic snapshots --compact
```

A snapshot listing proves the stored value opens the repository. `Fatal: wrong password or no key found` means the manager holds a wrong or outdated value — fix it now, while the client still exists and can produce the correct one.

If the nested SSH password prompt misbehaves, **on Linux** open a shared connection first and let restic reuse it:

```bash
ssh -M -S ~/.ssh/sb.sock -fN storagebox        # asks for the password once
restic -r sftp:storagebox:/home/restic -o sftp.command='ssh -S ~/.ssh/sb.sock storagebox -s sftp' snapshots --compact
ssh -S ~/.ssh/sb.sock -O exit storagebox       # close it again
```

**On Windows it depends on the build.** The Microsoft one — what `scoop install openssh` and winget give you — cannot multiplex: a master connection dies with `getsockname failed: Not a socket`, because the native port does not implement Unix-domain sockets for this (verified with 10.0p2 on 05.09.2026). An MSYS/Cygwin build such as the `ssh.exe` bundled with Git for Windows is compiled from the Linux sources and should manage it; try the Linux commands above with that binary first. Only if that fails, generate a throwaway key, install it with the box password, and remove it from `/home/.ssh/authorized_keys` when the drill is over:

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\drill" -C "secrets-drill"
Get-Content "$env:USERPROFILE\.ssh\drill.pub" | ssh storagebox install-ssh-key
restic -r sftp:storagebox:/home/restic -o "sftp.command=ssh -i $env:USERPROFILE/.ssh/drill storagebox -s sftp" snapshots --compact
```

### Test C — Hetzner account

Sign in to `console.hetzner.com` in the browser of the drill machine, with password and second factor from the password manager. This is the account that owns the box snapshots, the password reset and the delete protection, so it is part of the recovery path.

**Optional, and the real proof:** restore one small folder here, exactly as in scenario 4 step 5. A restore that works on a machine that has never seen this backup before is the only complete answer.

### Quick variant on the client itself

Weaker, because it does not prove machine independence, but it catches a wrong stored value in a minute — read the value off your phone and type it, with the password file switched off for this one shell:

```powershell
Remove-Item Env:RESTIC_PASSWORD_FILE
restic snapshots --compact
```

### Afterwards

The `known_hosts` entry and the `Host storagebox` block are harmless leftovers, but the drill machine now has credentials in its shell history, and possibly a drill key on the box.

```bash
history -c && rm -f ~/.bash_history
```

```powershell
Remove-Item (Get-PSReadLineOption).HistorySavePath
```

If you used the Windows fallback: reconnect and reduce `/home/.ssh/authorized_keys` to the client key again, then delete `~\.ssh\drill*`.

### Two-factor recovery codes

The Hetzner account has 2FA. If the device holding the TOTP secret is lost, the account is locked - and with it the box snapshots, the password reset and every other emergency lever in this runbook. The recovery codes must therefore live somewhere that is neither the backup client nor the phone: printed on paper, or in a second password manager vault. Generate a fresh set under `accounts.hetzner.com` → 2FA settings if you did not keep the ones from the original setup.

---

## What the backup does not contain

- **Windows, installed programs, drivers.** Reinstall. Everything under `C:\Windows`, `Program Files*`, `scoop\apps`, `AppData\Local\Programs`.
- **Google-native documents** (Docs, Sheets, Slides). They exist only in Drive; the sync deliberately skips them. Drive's own version history and trash are their backup. If that worries you, `rclone copy gdrive: --drive-export-formats docx,xlsx,pptx` into a folder that *is* backed up.
- **Caches, package directories, build outputs, Docker/WSL images, iCloud placeholders**, `Temp`. See `restic-excludes.txt`.
- **Anything created less than six hours before the loss**, or a state that was overwritten between two snapshots.
- **Machine-bound secrets**: ssh-agent contents, rclone's OAuth token, git credentials, browser sessions.

## Set up now, not later

Two things this runbook relies on that are **not** in place yet:

1. **Automatic Storage Box snapshots** — Console → Storage Box → Snapshots → *Automatic snapshots*: daily, keep 7. This is the ransomware step B without having to be fast. A snapshot holds the delta since the previous one; restic mostly appends, so daily deltas are small except on Sundays when `prune` rewrites packs. The BX21 has 20 automatic slots; they count against the 5 TB.
2. **Hetzner account hygiene** — snapshots are only as safe as the account that can delete them: 2FA enabled, no Console session kept open on this machine, no API token stored on it.
3. **The three secrets in the password manager**, verified by actually opening the entry on a device that is not this machine.
