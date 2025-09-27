# About restic-backup-script

## Project Overview
This repository provides a Bash script (`restic-backup.sh`) and configuration (`restic-backup.conf`) for automated, encrypted backups using [restic](https://restic.net/). It targets VPS environments, backing up local directories to remote SFTP storage (e.g., Hetzner Storage Box) with client-side encryption, deduplication, and snapshot management.

## Key Files & Structure
- `restic-backup.sh`: Main script. Handles backup, restore, integrity checks, scheduling, notifications, and self-updating.
- `restic-backup.conf`: Central config. All operational parameters (sources, retention, logging, notifications, etc.) are set here.
- `restic-excludes.txt`: Patterns for files/directories to exclude from backups.
- `how-to/`: Step-by-step guides for restoring, migrating, troubleshooting, and best practices.

## Essential Workflows
- **Run Modes**: Script supports multiple flags (`--restore`, `--check`, `--install-scheduler`, etc.). See `README.md` for full list and usage examples.
- **Configuration**: All settings (sources, repository, retention, notifications) are managed in `restic-backup.conf`. Use Bash array syntax for `BACKUP_SOURCES`.
- **Exclusions**: Update `restic-excludes.txt` or `EXCLUDE_PATTERNS` in config for custom exclusions.
- **Scheduling**: Use `--install-scheduler` to set up systemd/cron jobs interactively.
- **Self-Update**: Script can auto-update itself and restic binary if run interactively.
- **Notifications**: Integrates with ntfy and Discord for backup status alerts.
- **Healthchecks**: Optional integration for cron job monitoring via Healthchecks.io.

## Patterns & Conventions
- **Root Privileges**: Script enforces root execution (auto re-invokes with sudo).
- **Locking**: Prevents concurrent runs via `/tmp/restic-backup.lock`.
- **Logging**: Rotates logs at `/var/log/restic-backup.log` based on config.
- **Error Handling**: Uses `set -euo pipefail` for strict error management.
- **Color Output**: Uses ANSI colors for interactive output, disables for non-TTY.
- **Repository URL**: Uses SSH config alias for SFTP (e.g., `sftp:storagebox:/home/vps`).
- **Restore Safety**: Guides recommend restoring to temp directories before overwriting live data.

## Integration Points
- **restic**: Main dependency. Script checks, installs, and verifies restic binary.
- **SFTP/SSH**: Repository access via SSH config alias. Ensure `/root/.ssh/config` is set up.
- **ntfy/Discord**: Notification endpoints configured in `restic-backup.conf`.
- **Healthchecks.io**: Optional dead man's switch for scheduled jobs.

## Examples
- To run a backup: `sudo ./restic-backup.sh`
- To restore: `sudo ./restic-backup.sh --restore` (interactive wizard)
- To check integrity: `sudo ./restic-backup.sh --check`
- To install scheduler: `sudo ./restic-backup.sh --install-scheduler`

## References
- See `README.md` for feature overview and usage.
- See `how-to/` for guides on restore, migration, troubleshooting, and best practices.
- See `restic-backup.conf` for all config options and conventions.
