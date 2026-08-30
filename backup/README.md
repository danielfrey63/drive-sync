# backup — restic off-site backup to a Hetzner Storage Box

The sync in the parent directory is a mirror: a deletion or an encrypting malware reaches the cloud within seconds. This directory adds the thing a mirror is not — an independent, versioned, client-side encrypted copy of `C:` (user data, no OS or program files) and `D:\Meine Ablage` on a [Hetzner Storage Box](https://www.hetzner.com/storage/storage-box/), written by [restic](https://restic.net) over SFTP.

## How it works

```
C:\  +  D:\Meine Ablage
        │  restic backup (VSS snapshot, content-defined chunking, AES-256)
        ▼
  ssh.exe storagebox -s sftp        Microsoft OpenSSH build, key from the Windows ssh-agent
        │  port 23, KEX sntrup761x25519 (post-quantum hybrid, enforced)
        ▼
  uXXXXXX.your-storagebox.de:/home/restic
```

- **Snapshots are pointer trees.** Every file is cut into content-defined chunks; a chunk is stored once, no matter how many snapshots reference it. A snapshot is a tree of pointers into those chunks — like a git commit — so taking one costs a metadata scan plus the changed chunks, not a copy.
- **Schedule:** every 6 h from 05:00 (05:00, 11:00, 17:00, 23:00), after the 04:00 bisync. The task runs elevated so that restic can take a VSS snapshot and read locked files (Outlook, browser profiles, running databases).
- **Retention** (`forget` after every run): every state for 7 days, then one per day for 30 days, then one per month for 12 months. `prune` frees the chunks no snapshot references any more and `check --read-data-subset=2%` reads back a random 2 % of the data — both on Sundays only, because they rewrite the index over SFTP.
- **Encryption:** restic, AES-256-CTR + Poly1305-AES, key derived from the repository password. Hetzner sees blobs with random content and random names, no file names, no directory structure.
- **Transport:** port 23 of the box is OpenSSH and negotiates `sntrup761x25519-sha512`, a hybrid post-quantum key exchange; port 22 is ProFTPD `mod_sftp` and only offers classical ECDH/DH. The `storagebox` host alias pins the PQ KEX, so a downgrade fails instead of silently connecting. Since the data on the wire is already restic-encrypted, this protects mainly the login, not the payload — but it is free.

## Files

| File | Purpose |
| --- | --- |
| `run-backup.ps1` | the pipeline: backup → forget → (Sundays) prune → check; lock, daily log, error summary. `-DryRun` scans without uploading, `-NoVss` skips the snapshot, `-SkipMaintenance` stops after the backup |
| `backup-config.ps1` | repository, password file, retention, schedule, pinned ssh command. Machine-specific overrides go into `backup-config.local.ps1` (gitignored) |
| `restic-excludes.txt` | what stays out (see *Decisions*) |
| `install-backup-task.ps1` | registers the elevated scheduled task (idempotent) |

Logs: `%LOCALAPPDATA%\drive-sync\logs\backup-<yyyyMMdd>.log`. restic cache: `%LOCALAPPDATA%\drive-sync\restic-cache`.

## One-time setup

The order matters: the SSH key must exist before the box is created, because the Hetzner Console only accepts a key in the creation form.

1. **Key** — a dedicated ed25519 key with passphrase, nothing else uses it:

   ```powershell
   ssh-keygen -t ed25519 -a 100 -C "hetzner-storagebox" -f "$env:USERPROFILE\.ssh\openssh\hetzner_sb"
   icacls "$env:USERPROFILE\.ssh\openssh\hetzner_sb" /inheritance:r /grant:r "$($env:USERNAME):R"
   Get-Content "$env:USERPROFILE\.ssh\openssh\hetzner_sb.pub" | Set-Clipboard
   ```

2. **Box** — [console.hetzner.cloud](https://console.hetzner.cloud) → Storage Boxes → Create: location (rescale never changes it), type (BX21 = 5 TB), paste the public key, set a strong password anyway (a key does not disable password login), enable **SSH-Support** (port 23) and **External reachability**, leave SMB and WebDAV off.

3. **Host keys** — fetch, compare the ED25519 fingerprint with the one shown in the Console, then trust:

   ```powershell
   $ms = "$env:USERPROFILE\scoop\apps\openssh\current"
   & "$ms\ssh-keyscan.exe" -p 23 uXXXXXX.your-storagebox.de | Out-File "$env:TEMP\sb.txt" -Encoding ascii
   & "$ms\ssh-keygen.exe" -lf "$env:TEMP\sb.txt"
   Get-Content "$env:TEMP\sb.txt" | Where-Object { $_ -match 'ssh-ed25519' } | Add-Content "$env:USERPROFILE\.ssh\known_hosts"
   ```

4. **ssh config** — append to `~/.ssh/config`:

   ```
   Host storagebox
       HostName uXXXXXX.your-storagebox.de
       User uXXXXXX
       Port 23
       IdentityFile ~/.ssh/openssh/hetzner_sb
       IdentitiesOnly yes
       KexAlgorithms sntrup761x25519-sha512@openssh.com
       HostKeyAlgorithms ssh-ed25519
   ```

5. **Agent** — load the key into the Windows `ssh-agent` service (it persists across reboots). Use the Microsoft build of `ssh-add`; the MSYS one from `git-with-openssh` cannot reach the service:

   ```powershell
   Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent
   & "$env:USERPROFILE\scoop\apps\openssh\current\ssh-add.exe" "$env:USERPROFILE\.ssh\openssh\hetzner_sb"
   ```

6. **Repository password** — 32 random bytes, readable only by you. Put it into the password manager **before** the first backup: a lost password means a lost backup, restic cannot recover it.

   ```powershell
   New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\restic" | Out-Null
   $b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Fill($b)
   [IO.File]::WriteAllText("$env:LOCALAPPDATA\restic\storagebox-password.txt", [Convert]::ToBase64String($b))
   icacls "$env:LOCALAPPDATA\restic\storagebox-password.txt" /inheritance:r /grant:r "$($env:USERNAME):R"
   ```

7. **Initialise and test**

   ```powershell
   scoop install restic
   $env:RESTIC_REPOSITORY = "sftp:storagebox:/home/restic"
   $env:RESTIC_PASSWORD_FILE = "$env:LOCALAPPDATA\restic\storagebox-password.txt"
   $o = "sftp.command=C:/Users/<you>/scoop/apps/openssh/current/ssh.exe storagebox -s sftp"
   restic init -o $o
   .\run-backup.ps1 -DryRun
   ```

8. **Task** — from an elevated PowerShell (the task needs *Run with highest privileges* for VSS):

   ```powershell
   .\install-backup-task.ps1
   ```

   The start boundary is today 05:00, which is already in the past when you register during the day, so the task starts immediately — that is the initial run. Expect it to take days over a home uplink; a run cut off by the 20 h limit resumes from the repository index at the next slot without re-uploading finished chunks.

## Daily use

All `restic` calls need the pinned ssh command. Define it once per shell:

```powershell
$env:RESTIC_REPOSITORY = "sftp:storagebox:/home/restic"
$env:RESTIC_PASSWORD_FILE = "$env:LOCALAPPDATA\restic\storagebox-password.txt"
$o = "sftp.command=C:/Users/<you>/scoop/apps/openssh/current/ssh.exe storagebox -s sftp"
```

| Task | Command |
| --- | --- |
| list snapshots | `restic snapshots -o $o --compact` |
| what changed between two | `restic diff <id1> <id2> -o $o` |
| browse a snapshot | `restic ls latest -o $o "/D/Meine Ablage/Develop"` |
| restore one folder | `restic restore latest -o $o --target "D:\restore" --include "/D/Meine Ablage/Develop/danielfrey63/drive-sync"` |
| restore a file as it was last Tuesday | pick the snapshot id from `restic snapshots -o $o --compact`, then `restic restore <id> -o $o --target "D:\restore" --include "/C/Users/<you>/Documents/x.docx"` |
| find a file across snapshots | `restic find -o $o "*.kdbx"` |
| space used / dedup ratio | `restic stats -o $o --mode raw-data` |
| manual run now | `.\run-backup.ps1` (elevated for VSS) |
| tail the log | `Get-Content "$env:LOCALAPPDATA\drive-sync\logs\backup-$(Get-Date -Format yyyyMMdd).log" -Tail 20` |

Paths inside the repository are written `/C/Users/...` and `/D/Meine Ablage/...` — drive letters become the first path component, backslashes become slashes. Restoring a full snapshot recreates that layout under `--target` (`D:\restore\C\Users\...`); the one harmless error you will see is a failed timestamp on the read-only `Users` directory. `restic mount` does not exist on Windows (no FUSE) — use `ls`, `find`, `dump` and `restore --include` instead.

Step-by-step recovery scenarios — lost file, dead disk, new machine, ransomware — are in [RESTORE.md](RESTORE.md).

## Decisions

- **C: without OS and programs.** restic produces files, not a bootable image. Reinstall Windows, reinstall tools with scoop, restore the data — that is the realistic recovery path, so `C:\Windows`, `Program Files*`, `scoop\apps` and `scoop\cache` stay out; `scoop\persist` (application data) stays in.
- **D: only `Meine Ablage`.** `_trash-*`, `drive-sync-quarantine-*` and `tmp` are parking lots for discarded material.
- **`.git`, `.claude` and `.env` stay in**, unlike in the sync filters: unpushed commits are exactly what a backup is for, and the repository is encrypted and only readable locally. Package caches, build outputs, `node_modules`, `.venv`, `.metadata`, `CVS`, `.svn` stay out.
- **Docker/WSL images, browser caches, `Temp`, IDE caches** stay out — volatile, locked, reproducible.
- **iCloud Photos** stay out: 34'075 dehydrated placeholders whose content lives at Apple only (the provider is not running on this machine). Excluding them keeps the log readable; the error summary at the end of each log lists whatever else could not be read, grouped by cause.
- **Exclude-file syntax:** a literal `$` must be written `$$` (restic expands environment variables), comments only on their own line, `*` does not cross a path separator, `**` does.

## Why these tools

| Considered | Verdict |
| --- | --- |
| `rclone sync` + `crypt` | encrypted, but a mirror: no snapshots, no chunk deduplication, no VSS; `--backup-dir` versions whole files |
| Borg | the reference for this design, but no native Windows build and no NTFS/VSS support |
| Kopia | equivalent feature set with a GUI; restic chosen as the older, more conservative project |
| restic over `rclone serve restic` | not needed — the SFTP backend reaches the box directly, and rclone's Go SSH does not support the box's PQ key exchange (`sntrup761`) anyway |

## Troubleshooting

- **`Could not open a connection to your authentication agent`** — the `ssh`/`ssh-add` in `PATH` is the MSYS build from `git-with-openssh`; it talks to Cygwin sockets, not to the Windows service. Use `scoop\apps\openssh\current\*.exe`.
- **`exec: "C:": executable file not found`** — `sftp.command` was given with backslashes; restic splits it shell-style. Use forward slashes.
- **`Unable to negotiate ... no matching key exchange method`** — you are on port 22, or the box was moved to a host without `sntrup761`. Check with `ssh -vv storagebox 2>&1 | Select-String "kex: algorithm"`.
- **`Permission denied ()` on port 23** although the key is right — SSH-Support is disabled in the Console.
- **`backup finished with unreadable files (rc=3)`** — look at the error summary at the end of the log. *access denied* and *locked file* mean the run was not elevated; *cloud placeholder* means dehydrated OneDrive/iCloud files.
- **Repository locked after a crash** — `restic unlock -o $o` (only when no other restic is running; check the task).
- **`another backup is running`** in the log although none is — stale lock with a dead PID is taken over automatically; if the PID is alive, wait.
