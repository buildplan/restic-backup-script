# db-backup with helper script

Because `restic` reads files block-by-block, if a database engine updates a table file *while* `restic` is halfway through reading it, the resulting snapshot will contain a fractured, unbootable database.

To solve this on Linux VMs is to use a **Pre-Backup Dump Script**. This script securely exports the databases to static `.sql` or `.sql.gz` files, rotates old local copies to save space, and then hands the baton over to your `restic-backup.sh` script.

Here is an outline and a production-grade template for building this.

## 1. The Strategy

* **Secure Authentication:** Never hardcode database passwords in the script. Use native credential files (like `~/.my.cnf` for MySQL/MariaDB or `~/.pgpass` for PostgreSQL) secured with `600` permissions.
* **Compression:** Pipe the output directly into a compressor like `zstd` or `gzip`. This reduces local disk I/O and saves local storage.
* **Local Retention:** The script must clean up after itself (e.g., deleting local dumps older than 2 days). We rely on `restic` and your Hetzner box for long-term retention; the local files are just temporary staging.
* **Fail-Fast Execution:** If the database dump fails, the script should exit with an error so we don't back up corrupted or empty zero-byte files.

---

## 2. The Pre-Backup Script (`db-dump.sh`)

Create this file (e.g., at `/usr/local/bin/db-dump.sh`) and make it executable (`chmod +x /usr/local/bin/db-dump.sh`).

```bash
#!/usr/bin/env bash

# Database Pre-Backup Hook
# Application consistency by dumping databases to static files.

set -euo pipefail
umask 077

# --- Configuration ---
DUMP_DIR="/var/backups/db_dumps"
RETENTION_DAYS="2"
DATE_STAMP=$(date +%Y%m%d_%H%M%S)

# Determine what databases exist on this VM
HAS_MYSQL=$(command -v mysqldump || true)
HAS_POSTGRES=$(command -v pg_dumpall || true)

echo "--- Starting Database Dumps: ${DATE_STAMP} ---"

# Ensure dump directory exists securely
mkdir -p "$DUMP_DIR"
chmod 700 "$DUMP_DIR"

# --- 1. MySQL / MariaDB Dump ---
if [ -n "$HAS_MYSQL" ] && systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null; then
    echo "Dumping MySQL/MariaDB databases..."
    
    # Note: This assumes you have created a /root/.my.cnf file with credentials.
    # --single-transaction is CRITICAL for InnoDB tables to ensure consistency without locking the whole database.
    MYSQL_FILE="${DUMP_DIR}/mysql_all_${DATE_STAMP}.sql.gz"
    
    if mysqldump --defaults-extra-file=/root/.my.cnf --all-databases --single-transaction --quick --events --routines | gzip -9 > "$MYSQL_FILE"; then
        echo "✅ MySQL dump successful: $MYSQL_FILE"
    else
        echo "❌ MySQL dump failed!" >&2
        exit 1
    fi
fi

# --- 2. PostgreSQL Dump ---
if [ -n "$HAS_POSTGRES" ] && systemctl is-active --quiet postgresql 2>/dev/null; then
    echo "Dumping PostgreSQL databases..."
    
    PG_FILE="${DUMP_DIR}/postgres_all_${DATE_STAMP}.sql.gz"
    
    # Run as the postgres user to avoid needing passwords for local socket connections
    if su - postgres -c "pg_dumpall -c" | gzip -9 > "$PG_FILE"; then
        echo "✅ PostgreSQL dump successful: $PG_FILE"
    else
        echo "❌ PostgreSQL dump failed!" >&2
        rm -f "$PG_FILE" # Remove partial file
        exit 1
    fi
fi

# --- 3. Local Cleanup ---
echo "Cleaning up local dumps older than $RETENTION_DAYS days..."
find "$DUMP_DIR" -type f -name "*.sql.gz" -mtime +${RETENTION_DAYS} -delete

echo "--- Database Dumps Completed Successfully ---"
exit 0
```

## 3. Setting Up Authentication Files

If you are using MySQL/MariaDB, you must create the credentials file so the script runs unattended.

Create `/root/.my.cnf`:

```ini
[mysqldump]
user=root
password=your_secure_database_password
```

Secure it immediately:

```bash
chmod 600 /root/.my.cnf
```

## 4. Tying It All Together

Now that the databases are safely turning into static files, you need to update your `restic` setup to back them up and orchestrate the two scripts.

**Step A: Update `restic-backup.conf`**
Add the dump directory to your `BACKUP_SOURCES` in your configuration file:

```bash
BACKUP_SOURCES=("/home/user_files" "/var/backups/db_dumps")
```

### Step B: Update your Scheduler

If you used your script's `--install-scheduler` to set up a **cron job**, edit the crontab (`/etc/cron.d/restic-backup`) to chain the scripts together using `&&`. This ensures `restic` *only* runs if the database dump succeeds:

```cron
# Run db dump, and IF successful, run restic backup
00 03 * * * root /usr/local/bin/db-dump.sh && /path/to/restic-backup.sh >> "/var/log/restic-backup.log" 2>&1
```

If you used **systemd timers**, you can utilize `ExecStartPre` to run the dump before `restic` starts. Edit `/etc/systemd/system/restic-backup.service`:

```ini
[Service]
Type=oneshot
EnvironmentFile=/path/to/restic-backup.conf
# ADD THIS LINE:
ExecStartPre=/usr/local/bin/db-dump.sh
# Keep your existing ExecStart
ExecStart=/path/to/restic-backup.sh
User=root
Group=root
```

Then run `systemctl daemon-reload`.
