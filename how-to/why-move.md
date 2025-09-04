# Moving from `rsync` based backup to `restic`

## Key Advantages of Moving to Restic

**Built-in Client-Side Encryption**: Unlike rsync which stores data in plaintext on Hetzner, restic encrypts everything before it leaves VPS/VM. Even if Hetzner is compromised, data remains encrypted with keys they never see.[^1] [^2]

**Deduplication \& Compression**: Restic automatically deduplicates identical data blocks and compresses data, potentially using significantly less storage space than current rsync approach.[^2]

**Snapshot Management**: Instead of a "recycle bin", restic uses sophisticated retention policies with snapshots that can be restored individually or collectively.[^3] [^4]

## Migration Process

### 1. Install Restic

```bash
# Download and install restic
wget https://github.com/restic/restic/releases/latest/download/restic_*_linux_amd64.bz2
bunzip2 restic_*.bz2
chmod +x restic_*
sudo mv restic_* /usr/local/bin/restic
```


### 2. Set Up SSH Keys for Hetzner

Existing SSH key setup will work. Restic uses the same SFTP protocol:

```bash
# Test existing connection
ssh -p23 -i /root/.ssh/id_ed25519 u123456-sub4@u123456.your-storagebox.de pwd
```

#### Create the SSH Config File

This is a one-time setup. Create a file at `/root/.ssh/config` that defines an easy-to-remember alias for your storage box.

```bash
# Open the file in an editor
sudo nano /root/.ssh/config

# Add the following content, adjusting if needed:
Host storagebox
    HostName u123456.your-storagebox.de
    User u123456-sub4
    Port 23
    IdentityFile /root/.ssh/id_ed25519

# Set secure permissions
sudo chmod 600 /root/.ssh/config
```

### 3. Configuration Files

Three files that replicate current script's functionality:

- **Configuration file** with all current settings translated to restic equivalents
- **Main backup script** with similar features to rsync script
- **Exclude patterns** file based on current exclusions


### 4. Initial Setup

```bash
# Create password file for repository encryption
echo 'very-secure-password' | sudo tee /root/.restic-password
sudo chmod 600 /root/.restic-password

# Make scripts executable
chmod +x restic-backup-script.sh

# Initialize the encrypted repository
./restic-backup-script.sh --init
```


## Feature Comparison

| Current rsync Feature | Restic Equivalent | Status |
| :-- | :-- | :-- |
| **Multiple source directories** | Native support | ✅ Full |
| **SSH authentication** | SFTP backend | ✅ Full |
| **Encryption at rest** | **Built-in client-side** | ✅ **Enhanced** |
| **Notification system** | ntfy + Discord hooks | ✅ Full |
| **Recycle bin** | Retention policies | ✅ **Enhanced** |
| **Exclude patterns** | --exclude options | ✅ Full |
| **Integrity checks** | Built-in check command | ✅ **Enhanced** |
| **Dry run mode** | --dry-run flag | ✅ Full |
| **Restore functionality** | Native restore | ✅ **Enhanced** |
| **Logging \& rotation** | Custom logging | ✅ Full |
| **Bandwidth limiting** | External tools needed | ⚠️ Limited |
| **Progress reporting** | Built-in progress | ✅ Full |

## Enhanced Security Features

**Zero-Knowledge Encryption**: Encryption keys never leave the server. Hetzner cannot decrypt data even if compelled to do so.[^5] [^6]

**Tamper Detection**: Restic can detect if backup data has been modified or corrupted, providing integrity guarantees beyond what rsync offers.[^7]

**Snapshot Isolation**: Each backup creates an immutable snapshot. Even if server is compromised, attackers cannot retroactively modify historical backups.[^8]

## Usage Examples

```bash
# Normal backup (equivalent to current cron job)
./restic-backup-script.sh

# Dry run to see what would be backed up
./restic-backup-script.sh --dry-run

# Test configuration and connectivity
./restic-backup-script.sh --test

# Check repository integrity
./restic-backup-script.sh --check

# Interactive restore
./restic-backup-script.sh --restore

# Clean old snapshots according to retention policy
./restic-backup-script.sh --forget
```


## Retention Policy Translation

`rsync` recycle bin approach translates to restic's retention policies:

```bash
# Instead of 30-day recycle bin, use:
--keep-daily 7      # Keep daily snapshots for 1 week  
--keep-weekly 4     # Keep weekly snapshots for 1 month
--keep-monthly 12   # Keep monthly snapshots for 1 year
--keep-yearly 3     # Keep yearly snapshots for 3 years
```


## Notification Integration

The script maintains notification system:

```bash
# Same ntfy and Discord webhooks work
# Success: "Backup SUCCESS: hostname"
# Failure: "Backup FAILED: hostname" 
# With detailed statistics and timing
```


## Performance Considerations

**Network Efficiency**: Restic's deduplication means only changed blocks are transferred, often more efficient than rsync for subsequent backups.[^2]

**CPU Usage**: Client-side encryption requires more CPU than rsync, but the script uses `nice` and `ionice` to minimize impact.[^9]

**Storage Efficiency**: Deduplication and compression typically reduce storage usage by 20-60% compared to rsync.[^1]

This restic-based solution provides **superior security** through client-side encryption while maintaining the advanced features and reliability of current rsync setup. The encrypted data stored on Hetzner is completely inaccessible without local encryption keys.[^10] [^2]

<span style="display:none">[^11] [^12] [^13] [^14] [^15] [^16] [^17] [^18] [^19] [^20] [^21] [^22] [^23] [^24] [^25] [^26] [^27] [^28] [^29] [^30] [^31] [^32] [^33]</span>

<div style="text-align: center">⁂</div>

[^1]: https://glueck.dev/blog/using-restic-on-windows-to-backup-to-a-hetzner-storage-box

[^2]: https://simeon.staneks.de/en/posts/backup-cheap-and-easy/

[^3]: https://www.youtube.com/watch?v=G8xZPF8EJWk

[^4]: https://forum.restic.net/t/forget-policy/4014

[^5]: https://borgbackup.readthedocs.io/en/stable/usage/init.html

[^6]: https://manpages.debian.org/testing/borgbackup/borg-init.1.en.html

[^7]: https://restic.readthedocs.io/en/v0.9.1/040_backup.html

[^8]: https://fluix.one/blog/hetzner-restic-append-only/

[^9]: https://forum.restic.net/t/simple-restic-sh-backup-script-w-hooks/9707

[^10]: https://kcore.org/2023/02/01/hetzner-storagebox-backups/

[^11]: [backup.conf](https://github.com/buildplan/rsync-backup-script/raw/refs/heads/main/backup.conf)

[^12]: [backup_script.sh](https://github.com/buildplan/rsync-backup-script/raw/refs/heads/main/backup_script.sh)

[^13]: https://blog.9wd.eu/posts/restic-autorestic-hetzner-storagebox/

[^14]: https://prinzpiuz.in/post/my_backup_strategies_part2/

[^15]: https://restic.readthedocs.io/en/latest/040_backup.html

[^16]: https://github.com/boulund/restic-backup

[^17]: https://github.com/restic/restic/issues/233

[^18]: https://forum.restic.net/t/rfc-script-for-simpler-restic-backups-and-maintenance/4623

[^19]: https://danieldewberry.com/blog/2025-01-31-automated-backups-with-restic/

[^20]: https://docs.ntfy.sh/publish/

[^21]: https://github.com/restic/restic/issues/1805

[^22]: https://ntfy.sh/docs/config/

[^23]: https://forum.restic.net/t/backup-level-verbose-1-5/2875

[^24]: https://blog.alexsguardian.net/posts/2023/09/12/selfhosting-ntfy

[^25]: https://forum.restic.net/t/different-log-file-in-windows-and-linux/3273

[^26]: https://forum.restic.net/t/retention-policy/4953

[^27]: https://www.reddit.com/r/selfhosted/comments/1hrsvgg/ntfy_selfhosted_push_notification_server_for_all/

[^28]: https://forum.restic.net/t/backup-script-error-logging-and-unlock-placement/1892

[^29]: https://forum.restic.net/t/forgetting-all-snapshots-with-a-specific-tags/1102

[^30]: https://openclassrooms.com/en/courses/7338151-set-up-backup-solutions/7741818-write-your-backup-script-with-restic

[^31]: https://restic.readthedocs.io/en/stable/060_forget.html

[^32]: https://creativeprojects.github.io/resticprofile/configuration/logs/index.html

[^33]: https://forum.restic.net/t/how-to-get-verbose-progress-updates-but-also-log-with-tee/2825

