To keep the backup running, you need to use a terminal multiplexer like **`screen`** or **`tmux`**. These tools create a persistent session on your remote VPS that continues to run even after you disconnect.

-----

## The Problem: Broken SSH Connections

When you run a command over SSH, it's tied to your connection. If the connection breaks for any reason (closing your laptop, losing Wi-Fi), the server sends a "hangup" signal to your command, which kills it.

-----

## The Solution: Using `screen`

The easiest and most common tool for this job is `screen`. It acts like a virtual terminal on your VPS that you can detach from and reattach to at any time.

Here's a simple step-by-step guide to run your initial backup.

### 1. Install `screen` on your VPS

If it's not already installed, connect to your VPS and run:

```sh
# For Debian/Ubuntu
sudo apt-get update && sudo apt-get install screen

# For CentOS/Fedora/RHEL
sudo dnf install screen
```

### 2. Start a New `screen` Session

On your VPS, start a new session and give it a memorable name, like "backup".

```sh
screen -S backup
```

Your terminal will clear and you'll be inside the new, persistent session. It will look just like your normal command prompt.

### 3. Run Your Backup Command

Inside the `screen` session, start your backup just as you did before.

```sh
sudo /home/alis/scripts/restic-backup/restic-backup.sh --verbose
```

The backup will now start running.

### 4. Detach and Disconnect Safely

Now you can safely "detach" from the session, leaving it running in the background. Press the following key combination:

**`Ctrl+A`**, then let go, and then press **`D`** (for detach).

You'll see a message like `[detached from ...backup]` and you'll be back in your original terminal. You can now close your SSH connection, and your laptop can go to sleep. The backup will continue to run on the VPS.

### 5. Reconnect and Check Progress

Later on, you can check the progress of your backup.

1.  SSH back into your VPS.
2.  "Reattach" to your running session with this command:
    ```sh
    screen -r backup
    ```

You'll be dropped right back into the session, looking at the live output of your backup script exactly where you left it.

-----

## How to Monitor Without Reattaching

Even without reattaching to the `screen` session, you can check on the backup's progress by tailing its log file from a normal SSH session:

```sh
sudo tail -f /var/log/restic-backup.log
```
