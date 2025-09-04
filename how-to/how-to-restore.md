## Guide to Restore an Accidentally Deleted File or Folder

Let's say you've just accidentally deleted an important folder, `/var/www/my-website/assets`. Here’s how to get it back.

### Step 1: Find a Snapshot from Before the Deletion

First, you need to find a backup snapshot that was created **before** the deletion happened.

1.  **List Recent Snapshots**: Use the `snapshots` command to see recent backups from the current server.

    ```sh
    # Navigate to your script directory
    cd /root/scripts/backup

    # List snapshots for this host
    sudo ./restic-backup.sh snapshots
    ```

2.  **Choose the Right Snapshot**: Look at the timestamps in the `Time` column. Find the most recent snapshot that was taken **before** you deleted the file. Copy its **ID** (the short string of letters and numbers in the first column, like `9b12d5b6`).

### Step 2: Find the Exact Path of the Item

Now, let's confirm the exact path of the folder within the snapshot. This step also allows you to browse the backup to see exactly what's in it.

1.  **Launch the Restore Wizard**: Start the interactive restore process.

    ```sh
    sudo ./restic-backup.sh --restore
    ```

2.  **Follow the Prompts to Browse**:

      * **Enter snapshot ID...**: Paste the snapshot **ID** you just copied.
      * **Would you like to list the contents... (y/n)**: Type `y` and press Enter.
      * **Browsing**: Your terminal will now show the entire file list from that snapshot inside the `less` viewer. You can use the arrow keys to scroll up and down, or type `/` followed by a search term (e.g., `/my-website`) to search for your deleted item. This is how you can find and confirm its exact path (e.g., `/var/www/my-website/assets`).
      * Once you have the path, press `q` to quit the file browser and exit the script for now.

### Step 3: Restore the Item to Its Original Location

Now that you have the snapshot ID and the exact path, you can perform the restore.

1.  **Launch the Restore Wizard Again**:

    ```sh
    sudo ./restic-backup.sh --restore
    ```

2.  **Follow the Prompts to Restore**:

      * **Enter snapshot ID...**: Paste the same snapshot **ID** again.
      * **Would you like to list the contents... (y/n)**: Type `n` this time, as you already know the path.
      * **Enter restore destination...**: Enter `/` (a single forward slash).
          * **Why?** When you tell `restic` to restore a *specific file* to the root directory (`/`), it intelligently places it back in its original location.
      * **Optional: Enter specific file(s) to restore...**: This is the most important step. Type the **full, exact path** to the item you want to restore. You can restore multiple items by separating them with spaces.
        ```
        # Example for restoring a folder and a single file
        /var/www/my-website/assets /etc/nginx/nginx.conf
        ```
      * **Dry Run**: The script will show a preview, confirming it will **only** restore the items you specified to their correct original locations.
      * **Proceed with the actual restore? (y/n)**: After verifying the plan, type `y` and press Enter.

That's it\! The deleted folder or file will instantly reappear in its original location, with its original contents and permissions intact.

### Verification ✅

Finally, check that your file or folder has been restored correctly.

```sh
# Check if the restored folder exists
ls -l /var/www/my-website/assets
```

This method is the fastest and safest way to recover from common mistakes, leveraging the powerful snapshot capabilities of `restic` and the user-friendly wizard you built.
