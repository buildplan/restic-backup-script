# Automated Encrypted Backups with Restic

[![Shell Script Linting](https://github.com/buildplan/restic-backup-script/actions/workflows/script-checks.yml/badge.svg?branch=main)](https://github.com/buildplan/restic-backup-script/actions/workflows/script-checks.yml)
[![CodeQL](https://github.com/buildplan/restic-backup-script/actions/workflows/github-code-scanning/codeql/badge.svg?branch=main)](https://github.com/buildplan/restic-backup-script/actions/workflows/github-code-scanning/codeql)

This script automates encrypted, deduplicated backups of local directories using Restic. It supports local and remote repositories (including SFTP targets like Hetzner Storage Boxes), scheduling, notifications, and safe restore workflows.

-----

## Features

- **Client-side encryption**: All data is encrypted locally before upload.
- **Deduplication and compression**: Store only unique blocks; tune compression and pack size.
- **Snapshot-based backups**: Browse and restore to any point in time.
- **Advanced retention policy**: Keep last/daily/weekly/monthly/yearly snapshots automatically.
- **Unified configuration**: Simple `restic-backup.conf` controls everything.
- **Notifications**: Send success/warning/failure to ntfy, Discord, Slack, and Microsoft Teams.
- **Flexible exclusions**: Exclude via file or inline patterns.
- **System-friendly**: Runs with `nice`/`ionice` (optional) to reduce system impact.
- **Multiple commands**:
  - Backup, dry-run, stats, check, check-full, diff, ls, unlock, snapshots, snapshots-delete, restore (interactive, background, sync).
- **Concurrency control**: Locking prevents overlapping runs; optional SFTP/read concurrency.
- **Logging and rotation**: Writes to a single log file, rotates old logs automatically.
- **Pre-flight validation**: Ensures dependencies, credentials, sources, and permissions are okay before running.
- **[Healthchecks.io](https://healthchecks.io) integration**: Optional scheduled job monitoring pings.
- **Secure Restic auto-install/update**:
  - Checks the latest Restic release, downloads checksums and PGP signature.
  - Verifies the signature and checksum before installing (x86_64 and aarch64 supported).
- **Optional script self-update (interactive)**: Checks GitHub release, downloads, verifies checksum, and updates the script.

-----

## Quick Start

For those familiar with setting up backup scripts, here is a fast track to get you up and running.

1. **Download files**

```sh
mkdir -p /root/scripts/backup && cd /root/scripts/backup
curl -LO https://raw.githubusercontent.com/buildplan/restic-backup-script/refs/heads/main/restic-backup.sh
curl -LO https://raw.githubusercontent.com/buildplan/restic-backup-script/refs/heads/main/restic-backup.conf
curl -LO https://raw.githubusercontent.com/buildplan/restic-backup-script/refs/heads/main/restic-excludes.txt
chmod +x restic-backup.sh
```

2. **Edit configuration**

- Update `restic-backup.conf` with repository details, backup sources, and password file.
- Secure it: `chmod 600 restic-backup.conf`

3. **Create password and initialize repository**

```sh
# Create the password file (use a strong, unique password)
echo 'your-very-secure-password' | sudo tee /root/.restic-password
sudo chmod 400 /root/.restic-password

# Initialize the repository
sudo ./restic-backup.sh --init
```

4. **First backup and schedule**

```sh
# Run the first backup with verbose output
sudo ./restic-backup.sh --verbose

# Set up a recurring schedule via wizard (systemd or cron)
sudo ./restic-backup.sh --install-scheduler
```

> Default log: `/var/log/restic-backup.log`

-----

## Usage

### Run Modes

- `sudo ./restic-backup.sh` — Run a standard backup (quiet; suitable for cron).
- `sudo ./restic-backup.sh --verbose` — Live progress and detailed output.
- `sudo ./restic-backup.sh --dry-run` — Preview changes, no snapshot created.
- `sudo ./restic-backup.sh --check` — Verify repository integrity (subset).
- `sudo ./restic-backup.sh --check-full` — Full data verification (slow).
- `sudo ./restic-backup.sh --test` — Validate configuration, permissions, connectivity.
- `sudo ./restic-backup.sh --fix-permissions --test` — Interactively fix file permissions (600/400) and test.
- `sudo ./restic-backup.sh --install-scheduler` — Interactive schedule wizard (systemd/cron).
- `sudo ./restic-backup.sh --uninstall-scheduler` — Remove the installed schedule.
- `sudo ./restic-backup.sh --restore` — Interactive restore wizard with dry-run preview.
- `sudo ./restic-backup.sh --background-restore <snapshot> <dest>` — Non-blocking background restore (logs to /tmp).
- `sudo ./restic-backup.sh --sync-restore <snapshot> <dest>` — Blocking restore suitable for cron/automation.
- `sudo ./restic-backup.sh --forget` — Apply retention policy (optionally prunes).
- `sudo ./restic-backup.sh --diff` — Summary of changes between the last two snapshots.
- `sudo ./restic-backup.sh --stats` — Repository stats (logical/physical sizes).
- `sudo ./restic-backup.sh --unlock` — Remove stale locks (with safety checks).
- `sudo ./restic-backup.sh --snapshots` — List snapshots.
- `sudo ./restic-backup.sh --snapshots-delete` — Interactively delete snapshots (irreversible).
- `sudo ./restic-backup.sh --ls [snapshot_id] [path ...]` — List files/dirs within a snapshot (paged with `less`).

Tip: `--verbose` is interactive; cron should use the default quiet mode. The script auto-reexecs with sudo if not run as root.

-----

## Restore modes

Script provides three distinct modes for restoring data, each designed for a different scenario.

### 1. Interactive Restore (`--restore`)

This is an interactive wizard for guided restores. It is the best option when you are at the terminal and need to find and recover specific files or directories.

- **Best for**: Visually finding and restoring specific files or small directories.
- **Process**:
  - Lists available snapshots for you to choose from.
  - Asks for a destination path.
  - Performs a "dry run" to show you what will be restored before making any changes.
  - Requires your confirmation before proceeding with the actual restore.
- **Safety**:
  - Warns on critical destinations (e.g., `/`, `/etc`, `/usr`, etc.) and requires typing `DANGEROUS` to proceed.
  - If restoring under `/home/<user>`, the script attempts to set ownership to that user.

**Usage:**

```sh
sudo ./restic-backup.sh --restore
```

### 2. Background Restore (`--background-restore`)

This mode is designed for restoring large amounts of data (e.g., a full server recovery) without needing to keep your terminal session active.

- **Best for**: Large, time-consuming restores or recovering data over a slow network connection.
- **How it works**:
  - This command is **non-interactive**. You must provide the snapshot ID and destination path as arguments.
  - The restore job is launched in the background, immediately freeing up the terminal.
  - All output is saved to a log file in `/tmp/`.
  - You’ll receive a success or failure notification (via ntfy, Discord, etc.) upon completion.

**Usage:**

```sh
# Restore the latest snapshot to a specific directory in the background
sudo ./restic-backup.sh --background-restore latest /mnt/disaster-recovery

# Restore a specific snapshot by its ID
sudo ./restic-backup.sh --background-restore a1b2c3d4 /mnt/disaster-recovery
```

### 3. Synchronous Restore (`--sync-restore`)

This mode runs the restore in the foreground and waits for it to complete before exiting. It's a reliable, non-interactive way to create a complete, consistent copy of backup data.

- **Best for**: Creating a secondary copy of backup (for example, via a cron job) on another server (for a 3-2-1 strategy) or for use in any automation where subsequent steps depend on the restore being finished.
- **How it works**:
  - Non-interactive; requires snapshot ID and destination path as arguments.
  - Runs as a synchronous (blocking) process. Cron won’t finish until the restore is complete.
  - Guarantees the data copy is finished before any other commands are run or the cron job is marked complete.

**Usage:**

```sh
# On a second server, pull a full copy of the latest backup
sudo ./restic-backup.sh --sync-restore latest /mnt/local-backup-copy

# On your secondary server, run a sync-restore every day at 5:00 AM.
0 5 * * * /path/to/your/script/restic-backup.sh --sync-restore latest /path/to/local/restore/copy >> /var/log/restic-restore.log 2>&1

# Ensure a process runs only after a restore
sudo ./restic-backup.sh --sync-restore latest /srv/app/data && systemctl restart my-app
```

-----

## Diagnostics & Exit Codes

The script uses specific exit codes for different failures to help with debugging automated runs.

- **Exit Code `1`:** A fatal configuration error, such as a missing `restic-backup.conf` file or required variable.
- **Exit Code `5`:** Lock contention; another instance of the script is already running.
- **Exit Code `10`:** A required command (like `restic` or `curl`) is not installed.
- **Exit Code `11`:** The `RESTIC_PASSWORD_FILE` cannot be found.
- **Exit Code `12`:** The script cannot connect to or access the Restic repository.
- **Exit Code `13`:** A source directory in `BACKUP_SOURCES` does not exist or is not readable.
- **Exit Code `14`:** The `EXCLUDE_FILE` is not readable.
- **Exit Code `15`:** The `LOG_FILE` is not writable.
- **Exit Code `20`:** The `restic init` command failed.

Tip: `--test` runs a full pre-flight validation. `--fix-permissions` is interactive-only; in non-interactive (cron) mode, AUTO_FIX_PERMS is ignored for safety.

-----

## File Structure

All files should be placed in a single directory (e.g., `/root/scripts/backup`).

```bash
/root/scripts/backup/
├── restic-backup.sh      (main script)
├── restic-backup.conf    (settings and credentials)
└── restic-excludes.txt   (patterns to exclude from backup)
```

-----

## Setup Instructions

Follow these steps to get the backup system running from scratch.

### 1. Prerequisites

First, ensure the required tools are installed.

The script relies on several command-line tools to function correctly. Most are standard utilities, but you should ensure they are all present on your system.

#### Installation

You can install all required packages with a single command.

**On Debian or Ubuntu:**

```sh
sudo apt-get update && sudo apt-get install -y restic jq gnupg curl bzip2 util-linux coreutils less
```

**On CentOS, RHEL, or Fedora:**

```sh
sudo dnf install -y restic jq gnupg curl bzip2 util-linux coreutils less
```

You can also download and install the latest version of `restic`.

**Note:** While `restic` can be installed from your system's package manager, it is often an older version. It is **recommended** to install it manually or allow the script's built-in auto-updater to fetch the latest [official version](https://github.com/restic/restic/releases) for you.

```sh
# Find your architecture (e.g., x86_64 or aarch64)
uname -m
```

```sh
# Download the latest binary for your architecture from the Restic GitHub page
# https://github.com/restic/restic/releases
curl -LO <URL_of_latest_restic_linux_amd64.bz2>
```

```sh
# Unzip, make executable, and move to your path
bunzip2 restic_*.bz2
chmod +x restic_*
sudo mv restic_* /usr/local/bin/restic
```

-----

### Package Breakdown

| Package       | Required For                                                                                   |
| :------------ | :----------------------------------------------------------------------------------------------|
| **`restic`** | The core backup tool used for all repository operations (backup, restore, check, forget).       |
| **`jq`** | Parsing JSON to build diff summaries.                                                               |
| **`curl`** | Notifications and fetching release metadata.                                                      |
| **`bzip2`** | Decompressing the Restic binary during auto-install/update.                                      |
| **`gnupg`** | `gpg` for verifying the PGP signature of release checksums.                                      |
| **`util-linux`** | `flock` to prevent concurrent runs; `ionice` to reduce I/O impact.                          |
| **`coreutils`** | Utilities used throughout (e.g., `date`, `grep`, `sed`, `chmod`, `mv`, `mktemp`).            |
| **`less`** | Paging output for `--ls` and restore browsing.                                                    |

> Note: If you use the rclone backend (e.g., `RESTIC_REPOSITORY="rclone:remote:bucket/path"`), you must install and configure rclone separately.

-----

### 2. Configure Passwordless SSH Login (Recommended)

The most reliable way for the script to connect to a remote server is via an SSH config file.

1. **Generate a root SSH key** if one doesn't already exist:

    ```sh
    sudo ssh-keygen -t ed25519
    ```

    (Press Enter through all prompts).

2. **Add your public key** to the remote server's authorized keys. For a Hetzner Storage Box, paste the contents of `sudo cat /root/.ssh/id_ed25519.pub` into the control panel.
  
   For Hetzner Storagebox use the `ssh-copy-id` command (replace `u123456` and `u123456-sub4`):

    ```sh
    # Hetzner Storage Box requires the `-s` flag. Replace `u123456` and `u123456-sub4`
    
    sudo ssh-copy-id -p 23 -s u123456-sub4@u123456.your-storagebox.de
    ```

3. **Create an SSH config file** to define an alias for your connection:

    ```sh
    # Open the file in an editor
    sudo nano /root/.ssh/config
    ```

4. **Add the following content**, adjusting the details for your server:

    ```bash
    Host storagebox
        HostName u123456.your-storagebox.de
        User u123456-sub4
        Port 23
        IdentityFile /root/.ssh/id_ed25519
        ServerAliveInterval 60
        ServerAliveCountMax 240
    ```

5. **Set secure permissions** and test the connection:

    ```sh
    sudo chmod 600 /root/.ssh/config

    # This command should connect without a password and print "/home"
    sudo ssh storagebox pwd
    ```

-----

### 3. Place and Configure Files

1. Create your script directory:

    ```sh
    mkdir -p /root/scripts/backup && cd /root/scripts/backup
    ```

2. Download the script, configuration, and excludes files from the repository:

    ```sh
    # Download the main script
    curl -LO https://raw.githubusercontent.com/buildplan/restic-backup-script/refs/heads/main/restic-backup.sh

    # Download the configuration template
    curl -LO https://raw.githubusercontent.com/buildplan/restic-backup-script/refs/heads/main/restic-backup.conf

    # Download the excludes list
    curl -LO https://raw.githubusercontent.com/buildplan/restic-backup-script/refs/heads/main/restic-excludes.txt
    ```

3. **Make the script executable**:

    ```sh
    chmod +x restic-backup.sh
    ```

4. **Set secure permissions** for your configuration file:

    ```sh
    chmod 600 restic-backup.conf
    ```

5. **Edit `restic-backup.conf` and `restic-excludes.txt`** to specify your repository path, source directories, notification settings, and exclusion patterns.

### Configuration (`restic-backup.conf`)

All script behavior is controlled by the `restic-backup.conf` file. Below is an overview of the key settings available.

#### Core Settings

- `RESTIC_REPOSITORY`: Repository URL/connection string. Examples:
  - `sftp:storagebox:/home/u123456-sub4/restic`
  - `sftp:user@host:/path/to/repo`
  - `file:/srv/backups/restic`
  - `rclone:remote:bucket/path` (requires rclone installed/configured)
- `RESTIC_PASSWORD_FILE`: Absolute path to the file containing your repository password (recommended: `/root/.restic-password` with `chmod 400`).
- `BACKUP_SOURCES`: Bash array of local paths to back up, e.g.:
  - `BACKUP_SOURCES=("/etc" "/var/www" "/home")`

#### Retention Policy

You can define how many snapshots to keep for various timeframes. The script will automatically remove older snapshots that fall outside these rules.

- `KEEP_LAST`: Number of the most recent snapshots to keep.
- `KEEP_DAILY`: Number of daily snapshots to keep.
- `KEEP_WEEKLY`: Number of weekly snapshots to keep.
- `KEEP_MONTHLY`: Number of monthly snapshots to keep.
- `KEEP_YEARLY`: Number of yearly snapshots to keep.
  - Example: `KEEP_DAILY=7 KEEP_WEEKLY=4 KEEP_MONTHLY=12 KEEP_YEARLY=3`
- `PRUNE_AFTER_FORGET=true|false` — Run `restic prune` after applying retention.

#### Notifications

The script can send detailed status notifications to multiple services. Each can be enabled or disabled individually.

- `NTFY_ENABLED`: Set to `true` to enable ntfy notifications.
- `DISCORD_ENABLED`: Set to `true` to enable Discord notifications.
- `SLACK_ENABLED`: Set to `true` to enable Slack notifications.
- `TEAMS_ENABLED`: Set to `true` to enable Microsoft Teams notifications.
- Provide the corresponding `_URL` and/or `_TOKEN` for each service you enable.

#### Exclusions

You have two ways to exclude files and directories from your backups:

1. **`EXCLUDE_FILE`**: Point this to a text file (like `restic-excludes.txt`) containing one exclusion pattern per line.
2. **`EXCLUDE_PATTERNS`**: A space-separated list of patterns to exclude directly in the configuration file (e.g., `*.tmp *.log`).

#### Performance and behavior

- `LOW_PRIORITY=true|false` — Use `nice`/`ionice` (defaults true)
  - `NICE_LEVEL=19` — Nice level if `LOW_PRIORITY=true`
  - `IONICE_CLASS=3` — 3=idle, 2=best-effort, etc.
- `GOMAXPROCS_LIMIT` — Limit Go scheduler threads (sets `GOMAXPROCS`).
- `LIMIT_UPLOAD` — Restic `--limit-upload` (KiB/s).
- `SFTP_CONNECTIONS` — Sets `-o sftp.connections=<N>` for parallel SFTP connections.
- `READ_CONCURRENCY` — Restic `--read-concurrency <N>`.
- `COMPRESSION` — Restic `--compression auto|max|off|...` (requires Restic version with compression support).
- `PACK_SIZE` — Restic `--pack-size <MiB>`.
- `ONE_FILE_SYSTEM=true|false` — Restic `--one-file-system`.
- `RESTIC_CACHE_DIR=/var/cache/restic` — Use a persistent cache (recommended for speed).
- `PROGRESS_FPS_RATE=4` — Smoother progress updates when `--verbose` and interactive.
- `LOG_LEVEL=0|1|2|3` — Affects restic `--quiet/--verbose` flags:
  - 0: quiet, 1: default, 2: verbose, 3: extra verbose
  - `--verbose` flag forces level 2 for interactive runs.

#### Logging and rotation

- `LOG_FILE=/var/log/restic-backup.log` — Script appends logs here.
- `MAX_LOG_SIZE_MB=10` — Rotate when log exceeds this size.
- `LOG_RETENTION_DAYS=30` — Delete rotated logs older than N days.

#### Healthchecks

- `HEALTHCHECKS_URL` — If set, script pings on success; appends `/fail` on errors.

#### Restore safety

- The script warns and requires explicit confirmation when restoring to critical system paths.
- Optional: extend protected paths via `ADDITIONAL_CRITICAL_DIRS="/srv /data/critical"`.

#### Example minimal config

```bash
# Repository and credentials
RESTIC_REPOSITORY="sftp:storagebox:/home/u123456-sub4/restic"
RESTIC_PASSWORD_FILE="/root/.restic-password"

# What to back up
BACKUP_SOURCES=("/etc" "/var/www" "/home")

# Exclusions
EXCLUDE_FILE="/root/scripts/backup/restic-excludes.txt"

# Retention
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=12
KEEP_YEARLY=3
PRUNE_AFTER_FORGET=true

# Performance
LOW_PRIORITY=true
SFTP_CONNECTIONS=4
READ_CONCURRENCY=4
COMPRESSION=auto
PACK_SIZE=16
RESTIC_CACHE_DIR="/var/cache/restic"

# Logging
LOG_FILE="/var/log/restic-backup.log"
MAX_LOG_SIZE_MB=20
LOG_RETENTION_DAYS=60

# Notifications (ntfy example)
NTFY_ENABLED=true
NTFY_URL="https://ntfy.example.com/topic/restic"
NTFY_TOKEN="xxxxxxxxxxxxxxxx"
```

-----

### 4. Initial Repository Setup

Before the first backup, you need to create the repository password file and initialize the remote repository.

1. **Create the password file.** This stores the encryption key for your repository. **Guard this file carefully!**

    ```sh
    # Replace 'your-very-secure-password' with a strong, unique password
    echo 'your-very-secure-password' | sudo tee /root/.restic-password

    # Set secure permissions
    sudo chmod 400 /root/.restic-password
    ```

2. **Initialize the repository.** Run the script with the `--init` flag:

    ```sh
    # Navigate to your script directory
    cd /root/scripts/backup

    # Run the initialization
    sudo ./restic-backup.sh --init
    ```

-----

### 5. Set up an Automated Schedule (Recommended)

The easiest and most reliable way to schedule your backups is to use the script's built-in interactive wizard. It will guide you through creating and enabling either a modern `systemd timer` (recommended) or a traditional `cron` job.

1. Navigate to your script directory:

    ```sh
    cd /root/scripts/backup
    ```

2. Run the scheduler installation wizard:

    ```sh
    sudo ./restic-backup.sh --install-scheduler
    ```

Follow the on-screen prompts to choose your preferred scheduling system and frequency. The script will handle creating all the necessary files and enabling the service for you.

#### Manual Cron Job Setup

If you prefer to manage the schedule manually instead of using the wizard, you can edit the root crontab directly.

1. Open the crontab editor:

    ```sh
    sudo crontab -e
    ```

2. Add the following lines to schedule your backups and maintenance.

    ```crontab
    # Define a safe PATH that includes the location of restic
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

    # Run the Restic backup every day at 3:00 AM
    0 3 * * * /root/scripts/backup/restic-backup.sh > /dev/null 2>&1
 
    # Run the retention/prune job every Sunday at 4:00 AM 
    0 4 * * 0 /root/scripts/backup/restic-backup.sh --forget > /dev/null 2>&1

    # Cron job for a monthly full check (e.g., first Sunday of the month at 3 AM)
    0 3 * * 0 [ $(date +\%d) -le 07 ] && /root/scripts/backup/restic-backup.sh --check-full > /dev/null 2>&1
    ```

    - In your `restic-backup.conf`, set `PRUNE_AFTER_FORGET=true` to prune after retention.
    - For more details on retention, see the [Restic forget docs](https://restic.readthedocs.io/en/stable/060_forget.html).
    - Redirecting output to `/dev/null` is fine; the script manages its own logging and notifications.

-----

## Notes on updates

- Script self-update (interactive TTY only):
  - Checks the latest release of `buildplan/restic-backup-script`
  - Downloads the updated script and `.sha256`
  - Verifies checksum and updates itself
- Restic auto-install/update:
  - Handles download, signature verification, checksum verification, and installation to `/usr/local/bin/restic`
  - Skips auto-install in non-interactive (cron) mode; you’ll get a log notification

Both update checks run after the script acquires its lock, to avoid concurrent updates.

-----

## Security and best practices

- Run as root (the script re-execs with sudo automatically).
- Protect secrets:
  - `restic-backup.conf` should be `chmod 600`
  - `RESTIC_PASSWORD_FILE` should be `chmod 400`
- Consider using an SSH config for SFTP backends (ed25519 keys, non-default port, keepalives).
- For large repos, set `RESTIC_CACHE_DIR` to speed up operations.

-----

### [License](https://github.com/buildplan/restic-backup-script/blob/main/LICENSE)

This project is provided as-is. Refer to the repository for license information.
