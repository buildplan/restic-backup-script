## Quick Guide: Fixing a Stale Restic Lock

You'll know you have this issue if a backup fails with an error message like `unable to create lock in backend: repository is already locked`.

### Step 1: Check for Active Backups

This is a critical safety check to ensure you don't interrupt a legitimate, running backup. Run the following command:

```bash
ps aux | grep restic
```

If the only line in the output contains the word `grep`, it is safe to continue.

### Step 2: Unlock the Repository

Run the `restic unlock` command. You'll need to use the repository URL and password file path from your `restic-backup.conf` file.

```bash
sudo restic -r [YOUR_REPOSITORY_URL] --password-file [PATH_TO_PASSWORD_FILE] unlock
```

You should see a confirmation message, like `successfully removed 1 locks`.

### Step 3: Verify (Optional but Recommended)

Run a quick, non-destructive command like `snapshots` to confirm that the repository is accessible and healthy again.

```bash
sudo restic -r [YOUR_REPOSITORY_URL] --password-file [PATH_TO_PASSWORD_FILE] snapshots
```

-----

## What Causes Stale Locks?

This issue is not a bug, but a safety feature. A stale lock is left behind when a `restic` process that modifies the repository is stopped unexpectedly. Common causes include:

  * **Manually killing** a backup process (e.g., with `Ctrl+C`).
  * **Losing the network connection** or closing an SSH session during a backup.
  * A **server rebooting** while a backup is in progress.