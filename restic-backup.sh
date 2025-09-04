#!/bin/bash

# =================================================================
#         Restic Backup Script v0.05 - 2025.09.02
# =================================================================
# Based on rsync backup script but using restic for encrypted backups
# Provides similar functionality with client-side encryption

set -euo pipefail
umask 077

# --- Script Constants ---
SCRIPT_VERSION="0.05"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
CONFIG_FILE="${SCRIPT_DIR}/restic-backup.conf"
LOCK_FILE="/tmp/restic-backup.lock"
HOSTNAME=$(hostname -s)

# --- Color Palette ---
if [ -t 1 ]; then
    C_RESET='\e[0m'
    C_BOLD='\e[1m'
    C_DIM='\e[2m'
    C_RED='\e[0;31m'
    C_GREEN='\e[0;32m'
    C_YELLOW='\e[0;33m'
    C_CYAN='\e[0;36m'
else
    C_RESET=''
    C_BOLD=''
    C_DIM=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_CYAN=''
fi

# --- Ensure running as root ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${C_BOLD}${C_YELLOW}This script requires root privileges.${C_RESET}"
    echo -e "${C_YELLOW}Re-running with sudo...${C_RESET}"
    exec sudo "$0" "$@"
fi

# =================================================================
# CONFIGURATION LOADING
# =================================================================

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${C_RED}ERROR: Configuration file not found: $CONFIG_FILE${C_RESET}" >&2
    exit 1
fi

# Source configuration file
source "$CONFIG_FILE"

# Validate required configuration
REQUIRED_VARS=(
    "RESTIC_REPOSITORY"
    "RESTIC_PASSWORD_FILE"
    "BACKUP_SOURCES"
    "LOG_FILE"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo -e "${C_RED}ERROR: Required configuration variable '$var' is not set${C_RESET}" >&2
        exit 1
    fi
done

# =================================================================
# UTILITY FUNCTIONS
# =================================================================

check_and_install_restic() {
    echo -e "${C_BOLD}--- Checking Restic Version ---${C_RESET}"

    # Check for dependencies
    if ! command -v bzip2 &>/dev/null || ! command -v curl &>/dev/null; then
        echo -e "${C_RED}ERROR: 'bzip2' and 'curl' are required for auto-installation.${C_RESET}" >&2
        echo -e "${C_YELLOW}Please install them with: sudo apt-get install bzip2 curl${C_RESET}" >&2
        exit 1
    fi

    # Get the latest version tag from GitHub API
    local latest_version_tag
    latest_version_tag=$(curl -s "https://api.github.com/repos/restic/restic/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$latest_version_tag" ]; then
        echo -e "${C_YELLOW}Could not fetch latest restic version from GitHub. Skipping update check.${C_RESET}"
        return 0
    fi
    local latest_version="${latest_version_tag#v}"

    # Get the currently installed version, if any
    local local_version=""
    if command -v restic &>/dev/null; then
        local_version=$(restic version | head -n1 | awk '{print $2}')
    fi

    # Compare versions
    if [[ "$local_version" == "$latest_version" ]]; then
        echo -e "${C_GREEN}✅ Restic is up to date (version $local_version).${C_RESET}"
        return 0
    fi

    echo -e "${C_YELLOW}A new version of Restic is available ($latest_version). Current version is ${local_version:-not installed}.${C_RESET}"

    # Check if running in an interactive terminal
    if [ -t 1 ]; then
        # Interactive mode: Ask the user for confirmation
        read -p "Would you like to download and install it? (y/n): " confirm
        if [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]]; then
            echo "Skipping installation."
            return 0
        fi
    else
        # Non-interactive mode (cron): Log and skip installation
        log_message "New Restic version $latest_version available. Skipping interactive install in cron mode. Please update manually."
        echo "Skipping interactive installation in non-interactive mode (cron)."
        return 0
    fi
    local arch
    arch=$(uname -m)
    local arch_suffix=""
    case "$arch" in
        x86_64) arch_suffix="amd64" ;;
        aarch64) arch_suffix="arm64" ;;
        *)
            echo -e "${C_RED}Unsupported architecture '$arch'. Please install Restic manually.${C_RESET}" >&2
            return 1
            ;;
    esac
    local filename="restic_${latest_version}_linux_${arch_suffix}.bz2"
    local download_url="https://github.com/restic/restic/releases/download/${latest_version_tag}/${filename}"
    echo "Downloading from $download_url..."
    local temp_file
    temp_file=$(mktemp)
    if ! curl -sL -o "$temp_file" "$download_url"; then
        echo -e "${C_RED}Download failed. Please try installing manually.${C_RESET}" >&2
        rm -f "$temp_file"
        return 1
    fi
    echo "Decompressing and installing to /usr/local/bin/restic..."
    if bunzip2 -c "$temp_file" > /usr/local/bin/restic.tmp; then
        chmod +x /usr/local/bin/restic.tmp
        mv /usr/local/bin/restic.tmp /usr/local/bin/restic
        echo -e "${C_GREEN}✅ Restic version $latest_version installed successfully.${C_RESET}"
    else
        echo -e "${C_RED}Installation failed. Please try installing manually.${C_RESET}" >&2
    fi
    rm -f "$temp_file"
}

log_message() {
    local message="$1"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$HOSTNAME] [$timestamp] $message" >> "$LOG_FILE"

    if [[ "${VERBOSE_MODE:-false}" == "true" ]]; then
        echo -e "$message"
    fi
}

send_ntfy() {
    local title="$1"
    local tags="$2"
    local priority="$3"
    local message="$4"

    if [[ "${NTFY_ENABLED:-false}" != "true" ]] || [ -z "${NTFY_TOKEN:-}" ] || [ -z "${NTFY_URL:-}" ]; then
        return 0
    fi

    curl -s --max-time 15 \
        -u ":$NTFY_TOKEN" \
        -H "Title: $title" \
        -H "Tags: $tags" \
        -H "Priority: $priority" \
        -d "$message" \
        "$NTFY_URL" >/dev/null 2>>"$LOG_FILE"
}

send_discord() {
    local title="$1"
    local status="$2"
    local message="$3"

    if [[ "${DISCORD_ENABLED:-false}" != "true" ]] || [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
        return 0
    fi

    local color
    case "$status" in
        success) color=3066993 ;;
        warning) color=16776960 ;;
        failure) color=15158332 ;;
        *) color=9807270 ;;
    esac

    local escaped_title=$(echo "$title" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    local escaped_message=$(echo "$message" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')

    local json_payload
    printf -v json_payload '{"embeds": [{"title": "%s", "description": "%s", "color": %d, "timestamp": "%s"}]}' \
        "$escaped_title" "$escaped_message" "$color" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

    curl -s --max-time 15 \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        "$DISCORD_WEBHOOK_URL" >/dev/null 2>>"$LOG_FILE"
}

send_notification() {
    local title="$1"
    local tags="$2"
    local ntfy_priority="$3"
    local discord_status="$4"
    local message="$5"

    send_ntfy "$title" "$tags" "$ntfy_priority" "$message"
    send_discord "$title" "$discord_status" "$message"
}

setup_environment() {
    # Export restic environment variables
    export RESTIC_REPOSITORY
    export RESTIC_PASSWORD_FILE

    # Create exclude file from patterns
    if [ -n "${EXCLUDE_PATTERNS:-}" ]; then
        EXCLUDE_TEMP_FILE=$(mktemp)
        echo "$EXCLUDE_PATTERNS" | tr ' ' '\n' > "$EXCLUDE_TEMP_FILE"
    fi
}

cleanup() {
    # Remove temporary files
    [ -n "${EXCLUDE_TEMP_FILE:-}" ] && rm -f "$EXCLUDE_TEMP_FILE"

    # Release lock
    if [ -n "${LOCK_FD:-}" ]; then
        flock -u "$LOCK_FD"
    fi
}

run_preflight_checks() {
    local mode="${1:-backup}"

    # Check required commands
    local required_cmds=(restic curl flock)
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${C_RED}ERROR: Required command '$cmd' not found${C_RESET}" >&2
            exit 10
        fi
    done

    # Check password file
    if [ ! -f "$RESTIC_PASSWORD_FILE" ]; then
        echo -e "${C_RED}ERROR: Password file not found: $RESTIC_PASSWORD_FILE${C_RESET}" >&2
        exit 11
    fi

    # Check repository connectivity
    if ! restic cat config >/dev/null 2>&1; then
        if [[ "$mode" == "init" ]]; then
            return 0  # OK for init mode
        fi
        echo -e "${C_RED}ERROR: Cannot access repository. Run with --init first${C_RESET}" >&2
        exit 12
    fi

    # Check source directories (for backup mode)
    if [[ "$mode" == "backup" ]]; then
        for source in $BACKUP_SOURCES; do
            if [ ! -d "$source" ] || [ ! -r "$source" ]; then
                echo -e "${C_RED}ERROR: Source directory not accessible: $source${C_RESET}" >&2
                exit 13
            fi
        done
    fi
}

rotate_log() {
    if [ ! -f "$LOG_FILE" ]; then
        return 0
    fi

    local max_size_bytes=$(( ${MAX_LOG_SIZE_MB:-10} * 1024 * 1024 ))
    local log_size

    if command -v stat >/dev/null 2>&1; then
        log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    else
        log_size=0
    fi

    if [ "$log_size" -gt "$max_size_bytes" ]; then
        mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d_%H%M%S)"
        touch "$LOG_FILE"

        # Clean old rotated logs
        find "$(dirname "$LOG_FILE")" -name "$(basename "$LOG_FILE").*" \
            -type f -mtime +"${LOG_RETENTION_DAYS:-30}" -delete 2>/dev/null || true
    fi
}

build_restic_command() {
    local operation="$1"
    local restic_cmd=(restic)

    # Add verbosity
    case "${LOG_LEVEL:-1}" in
        0) restic_cmd+=(--quiet) ;;
        2) restic_cmd+=(--verbose) ;;
        3) restic_cmd+=(--verbose --verbose) ;;
    esac

    restic_cmd+=("$operation")

    case "$operation" in
        backup)
            [ -n "${BACKUP_TAG:-}" ] && restic_cmd+=(--tag "$BACKUP_TAG")
            [ -n "${COMPRESSION:-}" ] && restic_cmd+=(--compression "$COMPRESSION")
            [ -n "${PACK_SIZE:-}" ] && restic_cmd+=(--pack-size "$PACK_SIZE")
            [ "${ONE_FILE_SYSTEM:-false}" = "true" ] && restic_cmd+=(--one-file-system)
            [ -n "${EXCLUDE_FILE:-}" ] && [ -f "$EXCLUDE_FILE" ] && restic_cmd+=(--exclude-file "$EXCLUDE_FILE")
            [ -n "${EXCLUDE_TEMP_FILE:-}" ] && restic_cmd+=(--exclude-file "$EXCLUDE_TEMP_FILE")
            restic_cmd+=($BACKUP_SOURCES)
            ;;
        forget)
            [ -n "${KEEP_LAST:-}" ] && restic_cmd+=(--keep-last "$KEEP_LAST")
            [ -n "${KEEP_DAILY:-}" ] && restic_cmd+=(--keep-daily "$KEEP_DAILY")
            [ -n "${KEEP_WEEKLY:-}" ] && restic_cmd+=(--keep-weekly "$KEEP_WEEKLY")
            [ -n "${KEEP_MONTHLY:-}" ] && restic_cmd+=(--keep-monthly "$KEEP_MONTHLY")
            [ -n "${KEEP_YEARLY:-}" ] && restic_cmd+=(--keep-yearly "$KEEP_YEARLY")
            [ "${PRUNE_AFTER_FORGET:-true}" = "true" ] && restic_cmd+=(--prune)
            ;;
    esac

    echo "${restic_cmd[@]}"
}

run_with_priority() {
    local cmd=("$@")

    if [ "${LOW_PRIORITY:-true}" = "true" ]; then
        local priority_cmd=(nice -n "${NICE_LEVEL:-19}")

        if command -v ionice >/dev/null 2>&1; then
            priority_cmd+=(ionice -c "${IONICE_CLASS:-3}")
        fi

        priority_cmd+=("${cmd[@]}")
        "${priority_cmd[@]}"
    else
        "${cmd[@]}"
    fi
}

# =================================================================
# MAIN OPERATIONS
# =================================================================

init_repository() {
    echo -e "${C_BOLD}--- Initializing Repository ---${C_RESET}"

    if restic cat config >/dev/null 2>&1; then
        echo -e "${C_YELLOW}Repository already exists${C_RESET}"
        return 0
    fi

    log_message "Initializing new repository: $RESTIC_REPOSITORY"

    if restic init; then
        log_message "Repository initialized successfully"
        echo -e "${C_GREEN}✅ Repository initialized${C_RESET}"
        send_notification "Repository Initialized: $HOSTNAME" "white_check_mark" \
            "${NTFY_PRIORITY_SUCCESS}" "success" "Restic repository created successfully"
    else
        log_message "ERROR: Failed to initialize repository"
        echo -e "${C_RED}❌ Repository initialization failed${C_RESET}" >&2
        send_notification "Repository Init Failed: $HOSTNAME" "x" \
            "${NTFY_PRIORITY_FAILURE}" "failure" "Failed to initialize restic repository"
        exit 20
    fi
}

run_backup() {
    local start_time=$(date +%s)
    local backup_cmd

    echo -e "${C_BOLD}--- Starting Backup ---${C_RESET}"
    log_message "Starting backup of: $BACKUP_SOURCES"

    # Build and execute backup command
    backup_cmd=$(build_restic_command backup)

    local backup_log=$(mktemp)
    local backup_success=false

    if run_with_priority $backup_cmd 2>&1 | tee "$backup_log"; then
        backup_success=true
    fi

    # Parse backup results
    local files_new files_changed files_unmodified
    local data_added data_processed

    if grep -q "Files:" "$backup_log"; then
        files_new=$(grep "Files:" "$backup_log" | tail -1 | awk '{print $2}')
        files_changed=$(grep "Files:" "$backup_log" | tail -1 | awk '{print $4}')
        files_unmodified=$(grep "Files:" "$backup_log" | tail -1 | awk '{print $6}')
        data_added=$(grep "Added to the repository:" "$backup_log" | tail -1 | awk '{print $5" "$6}')
        data_processed=$(grep "processed" "$backup_log" | tail -1 | awk '{print $1" "$2}')
    fi

    cat "$backup_log" >> "$LOG_FILE"
    rm -f "$backup_log"

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [ "$backup_success" = true ]; then
        log_message "Backup completed successfully"
        echo -e "${C_GREEN}✅ Backup completed${C_RESET}"

        local stats_msg
        printf -v stats_msg "Files: %s new, %s changed, %s unmodified\nData added: %s\nDuration: %dm %ds" \
            "${files_new:-0}" \
            "${files_changed:-0}" \
            "${files_unmodified:-0}" \
            "${data_added:-Not applicable}" \
            "$((duration / 60))" \
            "$((duration % 60))"

        send_notification "Backup SUCCESS: $HOSTNAME" "white_check_mark" \
            "${NTFY_PRIORITY_SUCCESS}" "success" "$stats_msg"
    else
        log_message "ERROR: Backup failed"
        echo -e "${C_RED}❌ Backup failed${C_RESET}" >&2
        send_notification "Backup FAILED: $HOSTNAME" "x" \
            "${NTFY_PRIORITY_FAILURE}" "failure" "Backup failed after $((duration / 60))m ${duration % 60}s"
        return 1
    fi
}

run_forget() {
    echo -e "${C_BOLD}--- Cleaning Old Snapshots ---${C_RESET}"
    log_message "Running retention policy"

    local forget_cmd
    forget_cmd=$(build_restic_command forget)

    if run_with_priority $forget_cmd 2>&1 | tee -a "$LOG_FILE"; then
        log_message "Retention policy applied successfully"
        echo -e "${C_GREEN}✅ Old snapshots cleaned${C_RESET}"
    else
        log_message "WARNING: Retention policy failed"
        echo -e "${C_YELLOW}⚠️ Retention policy failed${C_RESET}" >&2
        send_notification "Backup Warning: $HOSTNAME" "warning" \
            "${NTFY_PRIORITY_WARNING}" "warning" "Retention policy failed but backup completed"
    fi
}

run_check() {
    echo -e "${C_BOLD}--- Checking Repository Integrity ---${C_RESET}"
    log_message "Running integrity check"

    if restic check --read-data-subset=5% 2>&1 | tee -a "$LOG_FILE"; then
        log_message "Integrity check passed"
        echo -e "${C_GREEN}✅ Repository integrity OK${C_RESET}"
    else
        log_message "WARNING: Integrity check failed"
        echo -e "${C_YELLOW}⚠️ Integrity check failed${C_RESET}" >&2
        send_notification "Repository Warning: $HOSTNAME" "warning" \
            "${NTFY_PRIORITY_WARNING}" "warning" "Repository integrity check failed"
    fi
}

run_restore() {
    echo -e "${C_BOLD}--- Restore Mode ---${C_RESET}"

    # List available snapshots
    echo "Available snapshots:"
    restic snapshots --compact
    echo

    # Get snapshot ID
    read -p "Enter snapshot ID to restore (or 'latest'): " snapshot_id
    if [ -z "$snapshot_id" ]; then
        echo "No snapshot specified, exiting"
        return 1
    fi

    # Offer to list snapshot contents to help find paths
    local list_confirm
    read -p "Would you like to list the contents of this snapshot to find exact paths? (y/n): " list_confirm
    if [[ "${list_confirm,,}" == "y" || "${list_confirm,,}" == "yes" ]]; then
        echo -e "${C_DIM}Displaying snapshot contents (use arrow keys to scroll, 'q' to quit)...${C_RESET}"
        restic ls -l "$snapshot_id" | less
    fi

    # Get restore destination
    read -p "Enter restore destination (absolute path): " restore_dest
    if [ -z "$restore_dest" ]; then
        echo "No destination specified, exiting"
        return 1
    fi

    # Ask for specific paths to include
    local include_paths=()
    read -p "Optional: Enter specific file(s) to restore, separated by spaces (leave blank for full restore): " -a include_paths
    
    local restic_cmd=(restic restore "$snapshot_id" --target "$restore_dest" --verbose)

    # Add --include flags if paths were provided
    if [ ${#include_paths[@]} -gt 0 ]; then
        for path in "${include_paths[@]}"; do
            restic_cmd+=(--include "$path")
        done
        echo -e "${C_YELLOW}Will restore only the specified paths...${C_RESET}"
    fi

    # Perform a dry run for user confirmation
    echo -e "${C_BOLD}\n--- Performing Dry Run (No changes will be made) ---${C_RESET}"
    if ! "${restic_cmd[@]}" --dry-run; then
        echo -e "${C_RED}❌ Dry run failed. Aborting restore.${C_RESET}" >&2
        return 1
    fi
    echo -e "${C_BOLD}--- Dry Run Complete ---${C_RESET}"

    # Ask for final confirmation before proceeding
    local proceed_confirm
    read -p "Proceed with the actual restore? (y/n): " proceed_confirm
    if [[ "${proceed_confirm,,}" != "y" && "${proceed_confirm,,}" != "yes" ]]; then
        echo "Restore cancelled by user."
        return 0
    fi

    # Create destination if it doesn't exist
    mkdir -p "$restore_dest"

    # Perform the actual restore
    echo -e "${C_BOLD}--- Performing Restore ---${C_RESET}"
    log_message "Restoring snapshot $snapshot_id to $restore_dest"

    if "${restic_cmd[@]}"; then
        log_message "Restore completed successfully"
        echo -e "${C_GREEN}✅ Restore completed${C_RESET}"

        # Set file ownership
        if [[ "$restore_dest" == /home/* ]]; then
            local dest_user
            dest_user=$(echo "$restore_dest" | cut -d/ -f3)

            if [[ -n "$dest_user" ]] && id -u "$dest_user" &>/dev/null; then
                echo -e "${C_CYAN}ℹ️  Home directory detected. Setting ownership of restored files to '$dest_user'...${C_RESET}"
                if chown -R "${dest_user}:${dest_user}" "$restore_dest"; then
                    log_message "Successfully changed ownership of $restore_dest to $dest_user"
                    echo -e "${C_GREEN}✅ Ownership set to '$dest_user'${C_RESET}"
                else
                    log_message "WARNING: Failed to change ownership of $restore_dest to $dest_user"
                    echo -e "${C_YELLOW}⚠️  Could not set file ownership. Please check permissions manually.${C_RESET}"
                fi
            fi
        fi

        send_notification "Restore SUCCESS: $HOSTNAME" "white_check_mark" \
            "${NTFY_PRIORITY_SUCCESS}" "success" "Restored $snapshot_id to $restore_dest"
    else
        log_message "ERROR: Restore failed"
        echo -e "${C_RED}❌ Restore failed${C_RESET}" >&2
        send_notification "Restore FAILED: $HOSTNAME" "x" \
            "${NTFY_PRIORITY_FAILURE}" "failure" "Failed to restore $snapshot_id"
        return 1
    fi
}

# =================================================================
# MAIN SCRIPT EXECUTION
# =================================================================

# Check for Restic and update if necessary
check_and_install_restic

# Set up signal handlers
trap cleanup EXIT
trap 'send_notification "Backup Crashed: $HOSTNAME" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "Backup script terminated unexpectedly"' ERR

# Parse command line arguments
VERBOSE_MODE=false
if [[ "${1:-}" == "--verbose" ]]; then
    VERBOSE_MODE=true
    shift
fi

# Acquire lock
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo -e "${C_RED}Another backup is already running${C_RESET}" >&2
    exit 5
fi
LOCK_FD=200

# Set up environment
setup_environment
rotate_log

# Handle different modes
case "${1:-}" in
    --init)
        run_preflight_checks "init"
        init_repository
        ;;
    --dry-run)
        echo -e "${C_BOLD}--- Dry Run Mode ---${C_RESET}"
        run_preflight_checks
        backup_cmd=$(build_restic_command backup)
        run_with_priority $backup_cmd --dry-run
        ;;
    --test)
        echo -e "${C_BOLD}--- Test Mode ---${C_RESET}"
        run_preflight_checks
        echo -e "${C_GREEN}✅ All tests passed${C_RESET}"
        ;;
    --restore)
        run_preflight_checks "restore"
        run_restore
        ;;
    --check)
        run_preflight_checks
        run_check
        ;;
    --forget)
        run_preflight_checks
        run_forget
        ;;
    *)
        # Default: full backup
        run_preflight_checks

        log_message "=== Starting backup run ==="

        if run_backup; then
            run_forget

            if [ "${CHECK_AFTER_BACKUP:-false}" = "true" ]; then
                run_check
            fi
        fi

        log_message "=== Backup run completed ==="
        ;;
esac

echo -e "${C_BOLD}--- Backup Script Completed ---${C_RESET}"
