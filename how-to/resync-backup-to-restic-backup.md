## Migration Plan Overview

The process involves five main steps:

1.  **Prepare the Storage Box**: Create a new, single directory that will become the unified `restic` repository.
2.  **Configure and Migrate the First VPS**: Fully set up the script on one of your servers (e.g., `cvps`), initialize the new repository, and run its first backup.
3.  **Migrate Additional VPSes**: Roll out the configuration to your other servers (e.g., `hvps`, `ivps`). This will be much faster as the repository is already created.
4.  **Verify and Automate**: Confirm that all your backups are running correctly and set up the new cron jobs.
5.  **Decommission the Old System**: After a safe period, disable the old `rsync` scripts and remove the old backup data to free up space.

-----

### Step 1: Prepare the Hetzner Storage Box

First, we'll create a new, clean directory on your storage box to house the `restic` repository. We will leave the old directories (`cvps`, `hvps`, etc.) untouched for now as a safety net.

1.  Connect to your Hetzner Storage Box via SSH.

2.  Create a new directory. Let's call it `restic-repo`.

    ```sh
    ssh your_storagebox_user@your_storagebox_host mkdir restic-repo
    ```

This single `restic-repo` directory will store the encrypted and deduplicated data from **all** your virtual private servers.

-----

### Step 2: Configure and Migrate the First VPS (e.g., `cvps`)

Now, let's set up the script on your first server. We'll use `cvps` as the example.

1.  **Deploy the Script**: Follow the setup instructions in your `README.md` on the `cvps` server. This includes installing `restic`, copying the script files (`restic-backup.sh`, `restic-backup.conf`, etc.), and creating the repository password file (e.g., `/root/.restic-password`).

2.  **Edit `restic-backup.conf`**: This is the most important part. Open the configuration file and make the following key adjustments:

      * **`RESTIC_REPOSITORY`**: Update this to point to the new, unified directory you created in Step 1. This path will be the **same for all your VPSes**.

        ```ini
        # Example for a user 'u123456' and the ssh alias 'storagebox'
        RESTIC_REPOSITORY="sftp:storagebox:/home/restic-repo"
        ```

      * **`RESTIC_PASSWORD_FILE`**: Ensure the path points to the password file you created. You must **use the same password file and password** on every VPS that will use this repository.

      * **`BACKUP_SOURCES`**: List the specific directories you want to back up from the `cvps` server.

        ```ini
        # Example for the cvps server
        BACKUP_SOURCES="/home/some_user /etc /var/www"
        ```

      * **`BACKUP_TAG`**: The default `daily-$(hostname)` is perfect. Leave it as is. It will automatically tag snapshots with the server's hostname (e.g., "cvps"), keeping your backups neatly organized.

3.  **Initialize the Repository**: From the `cvps` server, run the `--init` command. **You only need to do this ONCE** for the entire repository.

    ```sh
    # In your script directory on cvps
    sudo ./restic-backup.sh --init
    ```

4.  **Run the First Backup**: Perform the initial backup for `cvps`. This will take some time as it's uploading all the data for the first time.

    ```sh
    sudo ./restic-backup.sh --verbose
    ```

5.  **Verify the Backup**: Check that the snapshot was created successfully. The `host` column should show your `cvps` hostname.

    ```sh
    sudo ./restic-backup.sh snapshots
    ```

-----

### Step 3: Migrate Additional VPSes (`hvps`, `ivps`, etc.)

Now, adding your other servers is much easier. Let's use `hvps` as the next example.

1.  **Deploy and Configure**: Copy your configured script directory (with the updated `.conf` file) from `cvps` to `hvps`.

2.  **Edit `restic-backup.conf` on `hvps`**: The only change you need to make is to the `BACKUP_SOURCES` variable to reflect the directories you want to back up on the `hvps` server.

3.  **Copy the Password File**: Securely copy the `restic` password file to the same location on `hvps`.

4.  **Run the First Backup**: Run the backup command on `hvps`. **Do NOT run `--init` again\!**

    ```sh
    # In your script directory on hvps
    sudo ./restic-backup.sh --verbose
    ```

    You will likely notice that this backup is much faster and uploads significantly less data. This is `restic`'s deduplication at work\! Any files or data blocks that `hvps` has in common with `cvps` (like operating system files) will be skipped.

5.  **Repeat for All Other VPSes**: Follow the same process for `ivps` and any other servers you need to back up.

-----

### Step 4: Verify and Automate

After you've run the first backup for all your servers, run the `snapshots` command again from any of them. You should now see a list of snapshots from all your different hosts.

```sh
sudo ./restic-backup.sh snapshots
```

Once you've confirmed that all servers are backing up correctly, you can set up the cron job on each one, as described in your `README.md`.

-----

### Step 5: Decommission the Old System

Your new `restic` backup system is now fully operational.

1.  **Disable Old Cron Jobs**: Go to each VPS and comment out or remove the cron jobs that were running the old `rsync` scripts.

2.  **Wait and Verify**: Allow the new `restic` system to run for a safe period (e.g., a week or two) to ensure it is stable and reliable.

3.  **Clean Up the Storage Box**: Once you are confident in the new system, you can delete the old `rsync` directories (`amp1`, `cvps`, `hvps`, etc.) to reclaim a significant amount of disk space.

    ```sh
    # Be careful! This will permanently delete the old backups.
    ssh your_storagebox_user@your_storagebox_host "rm -rf amp1 amp2 archives avps bavps ccvps cvps dvps fvps g2vps gcvps gvps hvps"
    ```

You have now successfully migrated to a more secure, efficient, and modern backup system.
