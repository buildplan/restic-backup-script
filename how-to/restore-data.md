Restore data from one server's backup onto a completely new server. The process involves setting up your script on the new server and pointing it to the existing backup repository on your Hetzner Storage Box.

-----

## 1. Set Up the New Server

First, install and configure the backup script on new VPS.

  * **Install Dependencies**: Follow the "Prerequisites" section in the `README.md` to install `restic`, `jq`, `curl`, and other required tools on VPS2.
  * **Download Your Script**: Copy your entire script directory (containing `restic-backup.sh`, `restic-backup.conf`, etc.) from VPS1 to a suitable location on VPS2, like `/root/scripts/backup/`.
  * **Configure SSH**: Set up passwordless SSH access from VPS2 to your Hetzner Storage Box, just as you did for VPS1. This involves generating a new SSH key on VPS2 (`sudo ssh-keygen`) and adding the public key to your Storage Box's settings. Update `/root/.ssh/config` on VPS2 with the `Host storagebox` alias.
  * **Copy the Password File**: Securely copy your Restic password file (e.g., `/root/.restic-password`) from VPS1 to the exact same path on VPS2. Ensure its permissions are set to `400`.
  * **Configure the Script**: Edit `restic-backup.conf` on VPS2. The `RESTIC_REPOSITORY` and `RESTIC_PASSWORD_FILE` should be the same as on your old server. You can leave the `BACKUP_SOURCES` empty for now, as you are only restoring.

-----

## 2. Run the Restore

There are two main options for restoring the data, depending on your needs. Before you begin, it's helpful to see what data is available.

### A. Find the Data You Need

First, list the available snapshots to find the one you want to restore from. The `--snapshots` flag will show you all backups, including those from your old `vps1`.

```bash
sudo ./restic-backup.sh --snapshots
```

Once you have a snapshot ID (or if you just want the latest one), you can list its contents to find the exact path of the directory you want to restore.

```bash
# List all contents of the latest snapshot
sudo ./restic-backup.sh --ls latest

# List only the contents of a specific directory within the snapshot
sudo ./restic-backup.sh --ls latest "/path/to/directory"
```

### B. Choose a Restore Method

  * **For smaller restores or if you want to stay connected**: Use the interactive `--restore` wizard. It's user-friendly and shows you a dry run before starting.
    ```bash
    sudo ./restic-backup.sh --restore
    ```
  * **For large restores**: Use the non-interactive `--background-restore` command. This is ideal for restoring a large amount of data without needing to keep your terminal open.
    ```bash
    # Restore the latest snapshot to /mnt/data-from-vps1 in the background
    sudo ./restic-backup.sh --background-restore latest /mnt/data-from-vps1
    ```

-----

## 3. Correct File Ownership

After the restore is complete, the files will be owned by `root` because the script runs with `sudo`. If you restored the data to a user's home directory, the script's built-in logic will attempt to automatically correct the ownership.

If you restored to a different location (like `/srv/www`), you'll need to manually change the ownership. For example, to give ownership to the `www-data` user:

```bash
sudo chown -R www-data:www-data /srv/www
```
