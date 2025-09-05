# Automated Encrypted Backups with Restic

This script automates encrypted, deduplicated backups of local directories to a remote SFTP server (such as a Hetzner Storage Box) using `restic`.

-----

## Features

  - **Client-Side Encryption**: All data is encrypted on your server *before* being uploaded, ensuring zero-knowledge privacy from the storage provider.
  - **Deduplication & Compression**: Saves significant storage space by only storing unique data blocks and applying compression.
  - **Snapshot-Based Backups**: Creates point-in-time snapshots, allowing you to easily browse and restore files from any backup date.
  - **Advanced Retention Policies**: Sophisticated rules to automatically keep daily, weekly, monthly, and yearly snapshots.
  - **Unified Configuration**: All settings are managed in a single, easy-to-edit `restic-backup.conf` file.
  - **Notification Support**: Sends detailed success, warning, or failure notifications to ntfy and/or Discord.
  - **System Friendly**: Uses `nice` and `ionice` to minimize CPU and I/O impact during backups.
  - **Multiple Operation Modes**: Supports standard backups, dry runs, integrity checks, difference summaries, and a safe, interactive restore mode. 
  - **Concurrency Control & Logging**: Prevents multiple instances from running simultaneously and handles its own log rotation.
  - **Pre-run Validation**: Performs checks for required commands and repository connectivity before execution.

-----

## Usage

#### Run Modes:

  - `sudo ./restic-backup.sh` - Run a standard backup silently (suitable for cron).
  - `sudo ./restic-backup.sh --verbose` - Run with live progress and detailed output.
  - `sudo ./restic-backup.sh --dry-run` - Preview changes without creating a new snapshot.
  - `sudo ./restic-backup.sh --check` - Verify repository integrity by checking a subset of data.
  - `sudo ./restic-backup.sh --test` - Validate configuration, permissions, and SSH connectivity.
  - `sudo ./restic-backup.sh --restore` - Start the interactive restore wizard.
  - `sudo ./restic-backup.sh --forget` - Manually apply the retention policy and prune old data.
  - `sudo ./restic-backup.sh --diff` - Show a summary of changes between the last two snapshots. 
  - `sudo ./restic-backup.sh --init` - (One-time setup) Initialize the remote repository.

> *Default log location: `/var/log/restic-backup.log`*

#### Diagnostics & Error Codes

The script uses specific exit codes for different failures to help with debugging automated runs.

  - **Exit Code `1`:** A fatal configuration error, such as a missing `restic-backup.conf` file or required variable.
  - **Exit Code `5`:** Lock contention; another instance of the script is already running.
  - **Exit Code `10`:** A required command (like `restic` or `curl`) is not installed.
  - **Exit Code `11`:** The `RESTIC_PASSWORD_FILE` cannot be found.
  - **Exit Code `12`:** The script cannot connect to or access the Restic repository.
  - **Exit Code `13`:** A source directory in `BACKUP_SOURCES` does not exist or is not readable.
  - **Exit Code `20`:** The `restic init` command failed.

-----

## File Structure

All files should be placed in a single directory (e.g., `/root/scripts/backup`).

```
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
sudo apt-get update && sudo apt-get install -y restic jq curl bzip2 util-linux coreutils less
```

**On CentOS, RHEL, or Fedora:**

```sh
sudo dnf install -y restic jq curl bzip2 util-linux coreutils less
```

You could also download and install the latest version of `restic`. 

**Note:** While `restic` can be installed from your system's package manager, it is often an older version. It is **recommended** to install it manually or allow the script's built-in auto-updater to fetch the latest official version for you.

```sh
# Find your architecture (e.g., x86_64 or aarch64)
uname -m
```

```sh
# Download the latest binary for your architecture from the Restic GitHub page
# Example 0.18.0 is latest as of Aug,2025 for amd64:
curl -LO https://github.com/restic/restic/releases/download/v0.18.0/restic_0.18.0_linux_amd64.bz2
```

```sh
# Unzip, make executable, and move to your path
bunzip2 restic_*.bz2
chmod +x restic_*
sudo mv restic_* /usr/local/bin/restic
```

#### Package Breakdown

| Package       | Required For                                                                                                         |
| :------------ | :------------------------------------------------------------------------------------------------------------------- |
| **`restic`** | The core backup tool used for all repository operations (backup, restore, check, forget).                          |
| **`jq`** | Parsing JSON for diff function to show difference between last two snapshots.                            |
| **`curl`** | Sending notifications to ntfy/Discord and fetching the latest version information from the GitHub API.      |
| **`bzip2`** | Decompressing the `restic` binary when using the auto-install/update feature.                             |
| **`util-linux`** | Provides `flock` for preventing concurrent script runs and `ionice` for setting I/O priority.          |
| **`coreutils`** | Provides essential commands used throughout the script, such as `date`, `grep`, `sed`, `chmod`, `mv`, and `mktemp`. |
| **`less`** | Paging through the list of files during an interactive restore (`--restore` mode).                         |


### 2. Configure Passwordless SSH Login (Recommended)

The most reliable way for the script to connect to a remote server is via an SSH config file.

1.  **Generate a root SSH key** if one doesn't already exist:

    ```sh
    sudo ssh-keygen -t ed25519
    ```

    (Press Enter through all prompts).

2.  **Add your public key** to the remote server's authorized keys. For a Hetzner Storage Box, you can paste the contents of `sudo cat /root/.ssh/id_ed25519.pub` into the control panel.

3.  **Create an SSH config file** to define an alias for your connection:

    ```sh
    # Open the file in an editor
    sudo nano /root/.ssh/config
    ```

4.  **Add the following content**, adjusting the details for your server:

    ```
    Host storagebox
        HostName u123456.your-storagebox.de
        User u123456-sub4
        Port 23
        IdentityFile /root/.ssh/id_ed25519
        ServerAliveInterval 60
        ServerAliveCountMax 240
    ```

5.  **Set secure permissions** and test the connection:

    ```sh
    sudo chmod 600 /root/.ssh/config

    # This command should connect without a password and print "/home"
    sudo ssh storagebox pwd
    ```

### 3. Place and Configure Files

1.  Create your script directory:

    ```sh
    mkdir -p /root/scripts/backup && cd /root/scripts/backup
    ```

2.  Download the script, configuration, and excludes files from the repository:

    ```sh
    # Download the main script
    curl -LO https://github.com/buildplan/restic-backup-script/raw/refs/heads/main/restic-backup.sh

    # Download the configuration template
    curl -LO https://github.com/buildplan/restic-backup-script/raw/refs/heads/main/restic-backup.conf

    # Download the excludes list
    curl -LO https://github.com/buildplan/restic-backup-script/raw/refs/heads/main/restic-excludes.txt
    ```

3.  **Make the script executable**:

    ```sh
    chmod +x restic-backup.sh
    ```

4.  **Set secure permissions** for your configuration file:

    ```sh
    chmod 600 restic-backup.conf
    ```

5.  **Edit `restic-backup.conf` and `restic-excludes.txt`** to specify your repository path, source directories, notification settings, and exclusion patterns.

### 4. Initial Repository Setup

Before the first backup, you need to create the repository password file and initialize the remote repository.

1.  **Create the password file.** This stores the encryption key for your repository. **Guard this file carefully!**

    ```sh
    # Replace 'your-very-secure-password' with a strong, unique password
    echo 'your-very-secure-password' | sudo tee /root/.restic-password

    # Set secure permissions
    sudo chmod 400 /root/.restic-password
    ```

2.  **Initialize the repository.** Run the script with the `--init` flag:

    ```sh
    # Navigate to your script directory
    cd /root/scripts/backup

    # Run the initialization
    sudo ./restic-backup.sh --init
    ```

### 5. Set up a Cron Job

To run the backup automatically, edit the root crontab.

1.  Open the crontab editor:

    ```sh
    sudo crontab -e
    ```

2.  Add the following lines to schedule your backups and maintenance. 

    ```crontab
    # Define a safe PATH that includes the location of restic
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

    # Run the Restic backup every day at 3:00 AM
    0 3 * * * /root/scripts/backup/restic-backup.sh > /dev/null 2>&1
 
    # Run the retention/prune job every Sunday at 4:00 AM 
    0 4 * * 0 /root/scripts/backup/restic-backup.sh --forget > /dev/null 2>&1

    ```
    *For pune job in your `restic-backup.conf`, set `PRUNE_AFTER_FORGET=true`.*

    *Redirecting output to `/dev/null` is recommended, as the script handles its own logging and notifications.*
