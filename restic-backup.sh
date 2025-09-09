#!/bin/bash

# =================================================================
#         Restic Backup Script v0.22 - 2025.09.09
# =================================================================

set -euo pipefail
umask 077

# --- Script Constants ---
SCRIPT_VERSION="0.22"
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
# RESTIC AND SCRIPT SELF-UPDATE FUNCTIONS
# =================================================================

import_restic_key() {
    local fpr="CF8F18F2844575973F79D4E191A6868BD3F7A907"
    # Return successfully if key already exists
    gpg --list-keys "$fpr" >/dev/null 2>&1 && return 0
    local servers=(
        "hkps://keyserver.ubuntu.com"
        "hkps://keys.openpgp.org"
        "hkps://pgpkeys.eu"
    )
    for ks in "${servers[@]}"; do
        echo "Fetching restic release key from $ks ..."
        if gpg --keyserver "$ks" --recv-keys "$fpr"; then
            return 0
        fi
    done
    echo -e "${C_RED}Failed to import restic PGP key from all keyservers.${C_RESET}" >&2
    return 1
}

check_and_install_restic() {
    echo -e "${C_BOLD}--- Checking Restic Version ---${C_RESET}"

    if ! command -v bzip2 &>/dev/null || ! command -v curl &>/dev/null || ! command -v gpg &>/dev/null; then
        echo -e "${C_RED}ERROR: 'bzip2', 'curl', and 'gpg' are required for secure auto-installation.${C_RESET}" >&2
        echo -e "${C_YELLOW}On Debian based systems install with: sudo apt-get install bzip2 curl gnupg${C_RESET}" >&2
        exit 1
    fi
    local latest_version
    latest_version=$(curl -s "https://api.github.com/repos/restic/restic/releases/latest" | grep -o '"tag_name": "[^"]*"' | sed -E 's/.*"v?([^"]+)".*/\1/')
    if [ -z "$latest_version" ]; then
        echo -e "${C_YELLOW}Could not fetch latest restic version from GitHub. Skipping check.${C_RESET}"
        return 0
    fi
    local local_version=""
    if command -v restic &>/dev/null; then
        local_version=$(restic version | head -n1 | awk '{print $2}')
    fi
    if [[ "$local_version" == "$latest_version" ]]; then
        echo -e "${C_GREEN}✅ Restic is up to date (version $local_version).${C_RESET}"
        return 0
    fi
    echo -e "${C_YELLOW}A new version of Restic is available ($latest_version). Current version is ${local_version:-not installed}.${C_RESET}"
    if [ -t 1 ]; then
        read -p "Would you like to download and install it? (y/n): " confirm
        if [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]]; then
            echo "Skipping installation."
            return 0
        fi
    else
        log_message "New Restic version $latest_version available. Skipping interactive install in cron mode."
        echo "Skipping interactive installation in non-interactive mode (cron)."
        return 0
    fi
    if ! import_restic_key; then
        return 1
    fi
    local temp_binary temp_checksums temp_signature
    temp_binary=$(mktemp) && temp_checksums=$(mktemp) && temp_signature=$(mktemp)
    trap 'rm -f "$temp_binary" "$temp_checksums" "$temp_signature"' RETURN
    local arch=$(uname -m)
    local arch_suffix=""
    case "$arch" in
        x86_64) arch_suffix="amd64" ;;
        aarch64) arch_suffix="arm64" ;;
        *) echo -e "${C_RED}Unsupported architecture '$arch'.${C_RESET}" >&2; return 1 ;;
    esac
    local latest_version_tag="v${latest_version}"
    local filename="restic_${latest_version}_linux_${arch_suffix}.bz2"
    local base_url="https://github.com/restic/restic/releases/download/${latest_version_tag}"
    local curl_opts=(-sL --fail --retry 3 --retry-delay 2)
    echo "Downloading Restic binary, checksums, and signature..."
    if ! curl "${curl_opts[@]}" -o "$temp_binary"   "${base_url}/${filename}"; then echo "Download failed"; return 1; fi
    if ! curl "${curl_opts[@]}" -o "$temp_checksums" "${base_url}/SHA256SUMS"; then echo "Download failed"; return 1; fi
    if ! curl "${curl_opts[@]}" -o "$temp_signature" "${base_url}/SHA256SUMS.asc"; then echo "Download failed"; return 1; fi
    echo "Verifying checksum signature..."
    if ! gpg --verify "$temp_signature" "$temp_checksums" >/dev/null 2>&1; then
        echo -e "${C_RED}FATAL: Invalid signature on SHA256SUMS. Aborting.${C_RESET}" >&2
        return 1
    fi
    echo -e "${C_GREEN}✅ Checksum file signature is valid.${C_RESET}"
    echo "Verifying restic binary checksum..."
    local expected_hash
    expected_hash=$(awk -v f="$filename" '$2==f {print $1}' "$temp_checksums")
    local actual_hash
    actual_hash=$(sha256sum "$temp_binary" | awk '{print $1}')
    if [[ -z "$expected_hash" || "$expected_hash" != "$actual_hash" ]]; then
        echo -e "${C_RED}FATAL: Binary checksum mismatch. Aborting.${C_RESET}" >&2
        return 1
    fi
    echo -e "${C_GREEN}✅ Restic binary checksum is valid.${C_RESET}"
    echo "Decompressing and installing to /usr/local/bin/restic..."
    if bunzip2 -c "$temp_binary" > /usr/local/bin/restic.tmp; then
        chmod +x /usr/local/bin/restic.tmp
        mv /usr/local/bin/restic.tmp /usr/local/bin/restic
        echo -e "${C_GREEN}✅ Restic version $latest_version installed successfully.${C_RESET}"
    else
        echo -e "${C_RED}Installation failed.${C_RESET}" >&2
    fi
}

check_for_script_update() {
    if ! [ -t 0 ]; then
        return 0
    fi
    echo -e "${C_BOLD}--- Checking for script updates ---${C_RESET}"
    local SCRIPT_URL="https://raw.githubusercontent.com/buildplan/restic-backup-script/main/restic-backup.sh"
    local remote_version
    remote_version=$(curl -sL "$SCRIPT_URL" | grep 'SCRIPT_VERSION=' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$remote_version" ] || [[ "$remote_version" == "$SCRIPT_VERSION" ]]; then
        echo -e "${C_GREEN}✅ Script is up to date (version $SCRIPT_VERSION).${C_RESET}"
        return 0
    fi
    echo -e "${C_YELLOW}A new version of this script is available ($remote_version). You are running $SCRIPT_VERSION.${C_RESET}"
    read -p "Would you like to download and update now? (y/n): " confirm
    if [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]]; then
        echo "Skipping update."
        return 0
    fi
    local temp_script temp_checksum
    temp_script=$(mktemp)
    temp_checksum=$(mktemp)
    trap 'rm -f "$temp_script" "$temp_checksum"' RETURN
    local CHECKSUM_URL="${SCRIPT_URL}.sha256"
    local curl_opts=(-sL --fail --retry 3 --retry-delay 2)
    echo "Downloading script update..."
    if ! curl "${curl_opts[@]}" -o "$temp_script"   "$SCRIPT_URL";    then echo "Download failed"; return 1; fi
    if ! curl "${curl_opts[@]}" -o "$temp_checksum" "$CHECKSUM_URL";  then echo "Download failed"; return 1; fi
    echo "Verifying downloaded file integrity..."
    local remote_hash
    remote_hash=$(awk '{print $1}' "$temp_checksum")
    if [ -z "$remote_hash" ]; then
        echo -e "${C_RED}Could not read remote checksum. Aborting update.${C_RESET}" >&2
        return 1
    fi
    local local_hash
    local_hash=$(sha256sum "$temp_script" | awk '{print $1}')
    if [[ "$local_hash" != "$remote_hash" ]]; then
        echo -e "${C_RED}FATAL: Checksum mismatch! File may be corrupt or tampered with.${C_RESET}" >&2
        echo -e "${C_RED}Aborting update for security reasons.${C_RESET}" >&2
        return 1
    fi
    echo -e "${C_GREEN}✅ Checksum verified successfully.${C_RESET}"
    if ! grep -q "#!/bin/bash" "$temp_script"; then
         echo -e "${C_RED}Downloaded file does not appear to be a valid script. Aborting update.${C_RESET}" >&2
         return 1
    fi
    chmod +x "$temp_script"
    mv "$temp_script" "$0"
    if [ -n "${SUDO_USER:-}" ] && [[ "$SCRIPT_DIR" != /root* ]]; then
        chown "${SUDO_USER}:${SUDO_GID:-$SUDO_USER}" "$0"
    fi
    echo -e "${C_GREEN}✅ Script updated successfully to version $remote_version. Please run the command again.${C_RESET}"
    exit 0
}

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

display_help() {
    echo -e "${C_BOLD}${C_CYAN}Restic Backup Script (v${SCRIPT_VERSION})${C_RESET}"
    echo "A comprehensive script for managing encrypted, deduplicated backups with restic."
    echo
    echo -e "${C_BOLD}${C_YELLOW}USAGE:${C_RESET}"
    echo -e "  sudo $0 ${C_GREEN}[COMMAND]${C_RESET}"
    echo
    echo -e "${C_BOLD}${C_YELLOW}COMMANDS:${C_RESET}"
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "[no command]" "Run a standard backup and apply the retention policy."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--init" "Initialize a new restic repository (one-time setup)."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--diff" "Show a summary of changes between the last two snapshots."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--snapshots" "List all available snapshots in the repository."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--check" "Verify repository integrity by checking a subset of data."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--forget" "Manually apply the retention policy and prune old data."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--unlock" "Forcibly remove stale locks from the repository."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--restore" "Start the interactive restore wizard."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--dry-run" "Preview backup changes without creating a new snapshot."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--test" "Validate configuration, permissions, and SSH connectivity."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--help, -h" "Display this help message."
    echo
    echo -e "Use ${C_GREEN}--verbose${C_RESET} before any command for detailed live output (e.g., 'sudo $0 --verbose --diff')."
    echo
}

log_message() {
    local message="$1"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$HOSTNAME] [$timestamp] $message" >> "$LOG_FILE"

    if [[ "${VERBOSE_MODE:-false}" == "true" ]]; then
        echo -e "$message"
    fi
}

run_diff() {
    echo -e "${C_BOLD}--- Generating Backup Summary ---${C_RESET}"
    log_message "Generating backup summary (diff)"
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${C_YELLOW}jq not found; install jq for JSON parsing (apt/dnf install jq).${C_RESET}" >&2
        log_message "WARNING: jq not installed; cannot run JSON-based diff summary."
        return 1
    fi
    local path_args=()
    for p in $BACKUP_SOURCES; do
        path_args+=(--path "$p")
    done
    local snapshot_json
    if ! snapshot_json=$(restic snapshots --json --host "$HOSTNAME" "${path_args[@]}"); then
        echo -e "${C_RED}Error: Failed to list snapshots (host/paths).${C_RESET}" >&2
        log_message "ERROR: restic snapshots --json failed in run_diff."
        return 1
    fi
    local -a ids=()
    mapfile -t ids < <(echo "$snapshot_json" | jq -r 'sort_by(.time) | reverse | .[0:2] | .[].id')

    if (( ${#ids[@]} < 2 )); then
        echo -e "${C_YELLOW}Not enough snapshots for host/paths to generate a summary (need ≥2).${C_RESET}"
        log_message "Summary skipped: fewer than 2 snapshots for host/paths."
        return 0
    fi
    local snap_new="${ids[0]}"
    local snap_old="${ids[1]}"
    echo -e "${C_DIM}Comparing snapshot ${snap_old} (older) with ${snap_new} (newer)...${C_RESET}"
    local stats_json
    if ! stats_json=$(restic diff --json "$snap_old" "$snap_new" | jq -nR '
        reduce inputs as $line ({}; try ($line | fromjson) catch empty)
        | select(.message_type=="statistics")
    '); then
        echo -e "${C_RED}Error: Failed to generate diff statistics.${C_RESET}" >&2
        log_message "ERROR: restic diff --json failed between $snap_old and $snap_new."
        return 1
    fi
    if [ -z "$stats_json" ]; then
        local human
        human=$(restic diff "$snap_old" "$snap_new" || true)
        if [ -z "$human" ]; then
            echo -e "${C_GREEN}No changes detected between the last two snapshots.${C_RESET}"
            log_message "Diff found no changes."
            return 0
        fi
        echo -e "\n${C_BOLD}--- Diff Summary (fallback) ---${C_RESET}"
        echo "$human"
        echo -e "${C_BOLD}-------------------------------${C_RESET}"
        send_notification "Backup Summary: $HOSTNAME" "page_facing_up" \
            "${NTFY_PRIORITY_SUCCESS}" "success" "$human"
        log_message "Backup diff summary (fallback) sent."
        echo -e "${C_GREEN}✅ Backup summary sent.${C_RESET}"
        return 0
    fi
    local summary
    summary=$(echo "$stats_json" | jq -r '
      "Changed files: \(.changed_files)\n" +
      "Added: files \(.added.files), dirs \(.added.dirs), others \(.added.others), bytes \(.added.bytes)\n" +
      "Removed: files \(.removed.files), dirs \(.removed.dirs), others \(.removed.others), bytes \(.removed.bytes)"
    ')
    echo -e "\n${C_BOLD}--- Diff Summary ---${C_RESET}"
    echo "$summary"
    echo -e "${C_BOLD}--------------------${C_RESET}"
    local notification_title="Backup Summary: $HOSTNAME"
    local notification_message
    printf -v notification_message "Diff %s (older) → %s (newer):\n%s" "$snap_old" "$snap_new" "$summary"
    send_notification "$notification_title" "page_facing_up" \
        "${NTFY_PRIORITY_SUCCESS}" "success" "$notification_message"
    log_message "Backup diff summary sent."
    echo -e "${C_GREEN}✅ Backup summary sent.${C_RESET}"
}

run_snapshots() {
    echo -e "${C_BOLD}--- Listing Snapshots ---${C_RESET}"
    log_message "Listing all snapshots"

    if ! restic snapshots; then
        log_message "ERROR: Failed to list snapshots"
        echo -e "${C_RED}❌ Failed to list snapshots. Check repository connection and credentials.${C_RESET}" >&2
        return 1
    fi
}

run_unlock() {
    echo -e "${C_BOLD}--- Unlocking Repository ---${C_RESET}"
    log_message "Attempting to unlock repository"

    local lock_info
    lock_info=$(restic list locks --repo "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE")

    if [ -z "$lock_info" ]; then
        echo -e "${C_GREEN}✅ No locks found. Repository is clean.${C_RESET}"
        log_message "No stale locks found."
        return 0
    fi

    echo -e "${C_YELLOW}Found stale locks in the repository:${C_RESET}"
    echo "$lock_info"

    local other_processes
    other_processes=$(ps aux | grep 'restic ' | grep -v 'grep' || true)

    if [ -n "$other_processes" ]; then
        echo -e "${C_YELLOW}WARNING: Another restic process appears to be running:${C_RESET}"
        echo "$other_processes"
        read -p "Are you sure you want to proceed? This could interrupt a live backup. (y/n): " confirm
        if [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]]; then
            echo "Unlock cancelled by user."
            log_message "Unlock cancelled by user due to active processes."
            return 1
        fi
    else
        echo -e "${C_GREEN}✅ No other active restic processes found. It is safe to proceed.${C_RESET}"
    fi

    echo "Attempting to remove stale locks..."
    if restic unlock --repo "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE"; then
        echo -e "${C_GREEN}✅ Repository unlocked successfully.${C_RESET}"
        log_message "Repository unlocked successfully."
    else
        echo -e "${C_RED}❌ Failed to unlock repository.${C_RESET}" >&2
        log_message "ERROR: Failed to unlock repository."
        return 1
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
    echo -e "${C_BOLD}--- Running Pre-flight Checks ---${C_RESET}"

    # System Dependencies
    echo -e "\n  ${C_DIM}- Checking System Dependencies${C_RESET}"
    printf "    %-65s" "Required commands (restic, curl, flock)..."
    local required_cmds=(restic curl flock)
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "[${C_RED} FAIL ${C_RESET}]"
            echo -e "${C_RED}ERROR: Required command '$cmd' not found${C_RESET}" >&2
            exit 10
        fi
    done
    echo -e "[${C_GREEN}  OK  ${C_RESET}]"

    # Configuration Files
    echo -e "\n  ${C_DIM}- Checking Configuration Files${C_RESET}"
    printf "    %-65s" "Password file ('$RESTIC_PASSWORD_FILE')..."
    if [ ! -r "$RESTIC_PASSWORD_FILE" ]; then
        echo -e "[${C_RED} FAIL ${C_RESET}]"
        echo -e "${C_RED}ERROR: Password file not found or not readable: $RESTIC_PASSWORD_FILE${C_RESET}" >&2
        exit 11
    fi
    echo -e "[${C_GREEN}  OK  ${C_RESET}]"

    if [ -n "${EXCLUDE_FILE:-}" ]; then
        printf "    %-65s" "Exclude file ('$EXCLUDE_FILE')..."
        if [ ! -r "$EXCLUDE_FILE" ]; then
            echo -e "[${C_RED} FAIL ${C_RESET}]"
            echo -e "${C_RED}ERROR: The specified EXCLUDE_FILE is not readable: ${EXCLUDE_FILE}${C_RESET}" >&2
            exit 14
        fi
        echo -e "[${C_GREEN}  OK  ${C_RESET}]"
    fi

    printf "    %-65s" "Log file writability ('$LOG_FILE')..."
    if ! touch "$LOG_FILE" >/dev/null 2>&1; then
        echo -e "[${C_RED} FAIL ${C_RESET}]"
        echo -e "${C_RED}ERROR: The log file or its directory is not writable: ${LOG_FILE}${C_RESET}" >&2
        exit 15
    fi
    echo -e "[${C_GREEN}  OK  ${C_RESET}]"

    # Repository State
    echo -e "\n  ${C_DIM}- Checking Repository State${C_RESET}"
    printf "    %-65s" "Repository connectivity and credentials..."
    if ! restic cat config >/dev/null 2>&1; then
        if [[ "$mode" == "init" ]]; then
            echo -e "[${C_YELLOW} SKIP ${C_RESET}] (OK for --init mode)"
            return 0
        fi
        echo -e "[${C_RED} FAIL ${C_RESET}]"
        echo -e "${C_RED}ERROR: Cannot access repository. Check credentials or run --init first.${C_RESET}" >&2
        exit 12
    fi
    echo -e "[${C_GREEN}  OK  ${C_RESET}]"

    printf "    %-65s" "Stale repository locks..."
    local lock_info
    lock_info=$(restic list locks 2>/dev/null || true)
    if [ -n "$lock_info" ]; then
        echo -e "[${C_YELLOW} WARN ${C_RESET}]"
        echo -e "${C_YELLOW}    ⚠️  Stale locks found! This may prevent backups from running.${C_RESET}"
        echo -e "${C_DIM}    Run the --unlock command to remove them.${C_RESET}"
    else
        echo -e "[${C_GREEN}  OK  ${C_RESET}]"
    fi

    # Backup Sources
    if [[ "$mode" == "backup" || "$mode" == "diff" ]]; then
        echo -e "\n  ${C_DIM}- Checking Backup Sources${C_RESET}"
        for source in $BACKUP_SOURCES; do
            printf "    %-65s" "Source directory ('$source')..."
            if [ ! -d "$source" ] || [ ! -r "$source" ]; then
                echo -e "[${C_RED} FAIL ${C_RESET}]"
                echo -e "${C_RED}ERROR: Source directory not found or not readable: $source${C_RESET}" >&2
                exit 13
            fi
            echo -e "[${C_GREEN}  OK  ${C_RESET}]"
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

    # Offer to list snapshot contents
    local list_confirm
    read -p "Would you like to list the contents of this snapshot to find exact paths? (y/n): " list_confirm
    if [[ "${list_confirm,,}" == "y" || "${list_confirm,,}" == "yes" ]]; then
        echo -e "${C_DIM}Displaying snapshot contents (use arrow keys to scroll, 'q' to quit)...${C_RESET}"
        less -f <(restic ls -l "$snapshot_id")
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

    # Ask for final confirmation
    local proceed_confirm
    read -p "Proceed with the actual restore? (y/n): " proceed_confirm
    if [[ "${proceed_confirm,,}" != "y" && "${proceed_confirm,,}" != "yes" ]]; then
        echo "Restore cancelled by user."
        return 0
    fi

    # Create destination if it doesn't exist and perform the restore
    mkdir -p "$restore_dest"
    echo -e "${C_BOLD}--- Performing Restore ---${C_RESET}"
    log_message "Restoring snapshot $snapshot_id to $restore_dest"

    #  Restore Logic
    local restore_log
    restore_log=$(mktemp)
    local restore_success=false

    if "${restic_cmd[@]}" 2>&1 | tee "$restore_log"; then
        restore_success=true
    fi
    cat "$restore_log" >> "$LOG_FILE"

    # Handle failure of the restic command
    if [ "$restore_success" = false ]; then
        log_message "ERROR: Restore failed"
        echo -e "${C_RED}❌ Restore failed${C_RESET}" >&2
        send_notification "Restore FAILED: $HOSTNAME" "x" \
            "${NTFY_PRIORITY_FAILURE}" "failure" "Failed to restore $snapshot_id"
        rm -f "$restore_log"
        return 1
    fi

    # Check if the restore was successful
    if grep -q "Summary: Restored 0 files/dirs" "$restore_log"; then
        echo -e "\n${C_YELLOW}⚠️  Restore completed, but no files were restored.${C_RESET}"
        echo -e "${C_YELLOW}This usually means the specific path(s) you provided do not exist in this snapshot.${C_RESET}"
        echo "Please try the restore again and use the 'list contents' option to verify the exact path."
        log_message "Restore completed but restored 0 files (path filter likely found no match)."
        send_notification "Restore Notice: $HOSTNAME" "information_source" \
            "${NTFY_PRIORITY_SUCCESS}" "warning" "Restore of $snapshot_id completed but 0 files were restored. The specified path filter may not have matched any files in the snapshot."
    else
        log_message "Restore completed successfully"
        echo -e "${C_GREEN}✅ Restore completed${C_RESET}"

        # Set file ownership logic
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
    fi

    # Clean up the temporary log file
    rm -f "$restore_log"
}

# =================================================================
# MAIN SCRIPT EXECUTION
# =================================================================

# Check for script updates (interactive mode only)
check_for_script_update

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
    --snapshots)
        run_preflight_checks
        run_snapshots
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
    --diff)
        run_preflight_checks "diff"
        run_diff
        ;;
    --unlock)
        run_preflight_checks "unlock"
        run_unlock
        ;;
    --help | -h)
        display_help
        ;;
    *)
        if [ -n "${1:-}" ]; then
            echo -e "${C_RED}Error: Unknown command '$1'${C_RESET}\n" >&2
            display_help
            exit 1
        fi

        # Default: full backup
        run_preflight_checks

        log_message "=== Starting backup run ==="

        if run_backup; then
            # Only run forget/check if backup was successful
            run_forget

            if [ "${CHECK_AFTER_BACKUP:-false}" = "true" ]; then
                run_check
            fi
        fi

        log_message "=== Backup run completed ==="
        ;;
esac

echo -e "${C_BOLD}--- Backup Script Completed ---${C_RESET}"
