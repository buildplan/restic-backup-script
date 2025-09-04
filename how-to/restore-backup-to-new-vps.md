### Guiding Principle: Restore Safely, Not Destructively

The safest way to restore a server is to first place the backed-up files into a temporary, isolated directory on the new server. From there, you can inspect the data and manually move it to its final destination. This prevents old configuration files (like network settings) from breaking your new VPS.

-----

## Full Restore Guide for a New VPS

Here is the step-by-step process to restore data from an old server (e.g., `cvps-old`) onto a new one (`cvps-new`).

### Step 1: Prepare the New VPS for Access

Before you can restore, the new VPS needs to be able to connect to your `restic` repository on the Hetzner Storage Box.

1.  **Follow Your Own Setup Guide**: On the **new** VPS, follow the prerequisites and setup instructions from your `README.md`. This involves:

      * Installing `restic`, `curl`, and other required tools.
      * Creating a passwordless SSH login for the `root` user to your Storage Box (by setting up `/root/.ssh/config` and the SSH key).
      * Copying your entire backup script directory (containing `restic-backup.sh`, `restic-backup.conf`, etc.) to `/root/scripts/backup/`.
      * Securely copying your repository password file (e.g., from a password manager or another machine) to the correct location (e.g., `/root/.restic-password`).

2.  **Test Connectivity**: Run a simple `restic` command to confirm that the new VPS can access the repository. This command simply lists the snapshots without changing anything.

    ```sh
    # Navigate to your script directory
    cd /root/scripts/backup

    # Run the test
    sudo ./restic-backup.sh snapshots
    ```

    If you see a list of your previous backups, you are ready to proceed.

### Step 2: Identify the Snapshot to Restore

Next, you need to find the specific backup you want to restore.

1.  **Filter Snapshots by Hostname**: To avoid confusion, list only the snapshots from the **old** server you are replacing. For example, if the old server's hostname was `cvps-old`, run:

    ```sh
    sudo ./restic-backup.sh snapshots --host cvps-old
    ```

2.  **Copy the Snapshot ID**: Review the list and find the snapshot you want to restore (this is usually the most recent one). Copy its **ID**, which is the short alphanumeric string in the first column (e.g., `b1d4b689`).

### Step 3: Perform the Safe Restore

Now we'll use your script's interactive restore wizard to pull the data into a safe, temporary location.

1.  **Create a Temporary Directory**: Make a directory where all the restored files will be placed. `/mnt/restore` is a common choice.

    ```sh
    sudo mkdir -p /mnt/restore
    ```

2.  **Launch the Restore Wizard**: Start the interactive restore process using the `--restore` flag.

    ```sh
    sudo ./restic-backup.sh --restore
    ```

3.  **Follow the Prompts**: Your script will now guide you through the process:

      * **Enter snapshot ID...**: Paste the snapshot **ID** you copied in Step 2.
      * **Would you like to list the contents... (y/n)**: Type `n` and press Enter. For a full server restore, listing every single file is unnecessary and can be slow.
      * **Enter restore destination...**: Enter the full path to your temporary directory: `/mnt/restore`.
      * **Optional: Enter specific file(s) to restore...**: **Leave this blank and press Enter.** This tells `restic` to restore everything from the snapshot.
      * **Dry Run**: The script will now show you a preview of the files to be restored.
      * **Proceed with the actual restore? (y/n)**: After reviewing the dry run, type `y` and press Enter.

`restic` will now download the data and recreate the file structure from your old server inside `/mnt/restore`. For example, the old `/home/user_files` directory will now be at `/mnt/restore/home/user_files`.

### Step 4: Verify and Manually Move Data into Place

This is the most important step for ensuring the stability of your new server. Instead of blindly copying everything, you'll move data over selectively.

1.  **Inspect the Restored Data**: Look inside the temporary directory to see your old files.

    ```sh
    sudo ls -lA /mnt/restore/
    ```

2.  **Move Data Selectively**:

      * **Home Directories (Safe to move)**: User data is typically safe to move directly.

        ```sh
        # Example: Move a user's home directory
        sudo mv /mnt/restore/home/user_files /home/
        ```

      * **Web Server Data (Safe to move)**: Application data is also usually safe.

        ```sh
        # Example: Move web data
        sudo mv /mnt/restore/var/www/my_website /var/www/
        ```

      * **Configuration Files (Handle with EXTREME care)**: **DO NOT** copy the entire `/mnt/restore/etc` directory over `/etc`. This will overwrite the new server's network and SSH settings, locking you out. Instead, copy specific configuration files you need, one by one.

        ```sh
        # Example: Copying a specific Nginx config
        sudo cp /mnt/restore/etc/nginx/sites-available/my-site.conf /etc/nginx/sites-available/
        ```

3.  **Check Ownership and Permissions**: After moving files, double-check that the ownership and permissions are correct. `restic` preserves them, but it's always good to verify.

### Step 5: Cleanup and Finalize

Once you have moved all the data you need and have confirmed your applications are running correctly on the new VPS:

1.  **Remove the Temporary Directory**: Clean up the restored data to free up space.

    ```sh
    sudo rm -rf /mnt/restore
    ```

2.  **Enable Backups for the New Server**: Now that the server is fully configured, you can set up the cron job to ensure it gets backed up regularly, just like the others.
