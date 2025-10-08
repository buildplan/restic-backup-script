#!/usr/bin/env bash

# =================================================================
#         Restic Backup Script v0.38.2 - 2025.10.08
# =================================================================

set -euo pipefail
umask 077

# --- Script Constants ---
SCRIPT_VERSION="0.38.2"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
CONFIG_FILE="${SCRIPT_DIR}/restic-backup.conf"
LOCK_FILE="/tmp/restic-backup.lock"
HOSTNAME=$(hostname -s)

# --- Color Palette ---
if [ -t 1 ]; then
    C_RESET=$'\e[0m'
    C_BOLD=$'\e[1m'
    C_DIM=$'\e[2m'
    C_RED=$'\e[0;31m'
    C_GREEN=$'\e[0;32m'
    C_YELLOW=$'\e[0;33m'
    C_CYAN=$'\e[0;36m'
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
    # Check local user keyring
    if gpg --list-keys "$fpr" >/dev/null 2>&1; then
        return 0
    fi
    # Check Debian/Ubuntu system keyring
    local debian_keyring="/usr/share/keyrings/restic-archive-keyring.gpg"
    if [[ -f "$debian_keyring" ]]; then
        echo "Found debian keyring, checking for key..."
        if gpg --no-default-keyring --keyring "$debian_keyring" --list-keys "$fpr" >/dev/null 2>&1; then
            echo "Importing trusted key from system keyring..."
            gpg --no-default-keyring --keyring "$debian_keyring" --export "$fpr" | gpg --import >/dev/null 2>&1
            return $?
        fi
    fi
    # Try public keyservers fallback
    local servers=( "hkps://keys.openpgp.org" "hkps://keyserver.ubuntu.com" )
    for server in "${servers[@]}"; do
        echo "Attempting to fetch from $server..."
        if gpg --keyserver "$server" --recv-keys "$fpr"; then
            echo "Key imported successfully."
            return 0
        fi
    done
    echo "Failed to import restic PGP key." >&2
    return 1
}

display_update_info() {
    local component_name="$1"
    local current_version="$2"
    local new_version="$3"
    local release_notes="$4"
    echo
    echo -e "${C_BOLD}${C_YELLOW}A new version of ${component_name} is available!${C_RESET}"
    printf '  %-18s %s\n' "${C_CYAN}Current Version:${C_RESET}" "${current_version:--not installed-}"
    printf '  %-18s %s\n' "${C_GREEN}New Version:${C_RESET}"     "$new_version"
    echo
    if [ -n "$release_notes" ]; then
        echo -e "${C_YELLOW}Release Notes for v${new_version}:${C_RESET}"
        echo -e "    ${release_notes//$'\n'/$'\n'    }"
        echo
    fi
}

check_and_install_restic() {
    echo -e "${C_BOLD}--- Checking Restic Version ---${C_RESET}"
    if ! command -v less &>/dev/null || ! command -v bzip2 &>/dev/null || ! command -v curl &>/dev/null || ! command -v gpg &>/dev/null || ! command -v jq &>/dev/null; then
        echo
        echo -e "${C_RED}ERROR: 'less', 'bzip2', 'curl', 'gpg', and 'jq' are required for secure auto-installation.${C_RESET}" >&2
        echo
        echo -e "${C_YELLOW}On Debian based systems install with: sudo apt-get install less bzip2 curl gnupg jq${C_RESET}" >&2
        echo
        exit 1
    fi
    local release_info
    release_info=$(curl -s "https://api.github.com/repos/restic/restic/releases/latest")
    if [ -z "$release_info" ]; then
        echo -e "${C_YELLOW}Could not fetch latest restic version info from GitHub. Skipping check.${C_RESET}"
        return 0
    fi
    local latest_version
    latest_version=$(echo "$release_info" | jq -r '.tag_name | sub("^v"; "")')
    if [ -z "$latest_version" ]; then
        echo -e "${C_YELLOW}Could not parse latest restic version from GitHub. Skipping check.${C_RESET}"
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

    local release_notes
    release_notes=$(echo "$release_info" | jq -r '.body')
    display_update_info "Restic" "$local_version" "$latest_version" "$release_notes"

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
    local arch
    arch=$(uname -m)
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
    if ! command -v jq &>/dev/null; then
        echo -e "${C_YELLOW}Skipping script update check: 'jq' command not found.${C_RESET}"
        return 0
    fi
    echo -e "${C_BOLD}--- Checking for script updates ---${C_RESET}"    
    local SCRIPT_API_URL="https://api.github.com/repos/buildplan/restic-backup-script/releases/latest"
    local release_info
    release_info=$(curl -sL -H "Cache-Control: no-cache" -H "Pragma: no-cache" "$SCRIPT_API_URL")
    local remote_version
    remote_version=$(echo "$release_info" | jq -r '.tag_name | sub("^v"; "")')
    if [ -z "$remote_version" ] || [[ "$remote_version" == "$SCRIPT_VERSION" ]]; then
        echo -e "${C_GREEN}✅ Script is up to date (version $SCRIPT_VERSION).${C_RESET}"
        return 0
    fi
    local release_notes
    release_notes=$(echo "$release_info" | jq -r '.body // "Could not retrieve release notes."')
    display_update_info "this script" "$SCRIPT_VERSION" "$remote_version" "$release_notes"
    read -rp "Would you like to download and update now? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo "Skipping update."
        return 0
    fi
    local SCRIPT_URL="https://raw.githubusercontent.com/buildplan/restic-backup-script/main/restic-backup.sh"
    local CHECKSUM_URL="${SCRIPT_URL}.sha256"
    local temp_script temp_checksum
    temp_script=$(mktemp)
    temp_checksum=$(mktemp)
    trap 'rm -f "$temp_script" "$temp_checksum"' RETURN
    local curl_opts=(-sL --fail --retry 3 --retry-delay 2 -H "Cache-Control: no-cache" -H "Pragma: no-cache")
    echo "Downloading script update from raw file URL..."
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
    if ! grep -q -E "^#!/(usr/)?bin/(env )?bash" "$temp_script"; then
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
source "$CONFIG_FILE"
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
    local readme_url="https://github.com/buildplan/restic-backup-script/blob/main/README.md"
    local prog
    prog=$(basename "$0")

    echo -e "${C_BOLD}${C_CYAN}Restic Backup Script (v${SCRIPT_VERSION})${C_RESET}"
    echo "Encrypted, deduplicated backups with restic."
    echo
    echo -e "${C_BOLD}${C_YELLOW}USAGE:${C_RESET}"
    echo -e "  sudo $prog ${C_GREEN}[options] [command]${C_RESET}"
    echo
    echo -e "${C_BOLD}${C_YELLOW}OPTIONS:${C_RESET}"
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--verbose" "Show detailed live output."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--fix-permissions" "Interactive only: auto-fix 600/400 on conf/secret."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--help, -h" "Display this help message."
    echo
    echo -e "${C_BOLD}${C_YELLOW}COMMANDS:${C_RESET}"
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "[no command]" "Run a standard backup and apply the retention policy."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--init" "Initialize a new restic repository (one-time setup)."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--diff" "Show a summary of changes between the last two snapshots."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--snapshots" "List all available snapshots in the repository."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--snapshots-delete" "Interactively select and permanently delete snapshots."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--stats" "Display repository size and file counts."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--check" "Verify repository integrity (subset)."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--check-full" "Verify all repository data (slow)."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--forget" "Apply retention policy; optionally prune."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--unlock" "Remove stale repository locks."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--restore" "Interactive restore wizard."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--ls <snapshot_id>" "List files and directories inside a specific snapshot."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--background-restore" "Run a non-interactive restore in the background."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--sync-restore" "Run a non-interactive restore in the foreground (for cron)."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--dry-run" "Preview backup changes (no snapshot)."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--test" "Validate config, permissions, connectivity."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--install-scheduler" "Install an automated schedule (systemd/cron)."
    printf "  ${C_GREEN}%-20s${C_RESET} %s\n" "--uninstall-scheduler" "Remove an automated schedule."
    echo
    echo -e "${C_BOLD}${C_YELLOW}QUICK EXAMPLES:${C_RESET}"
    echo -e "  Run a backup now:            ${C_GREEN}sudo $prog${C_RESET}"
    echo -e "  Verbose diff summary:        ${C_GREEN}sudo $prog --verbose --diff${C_RESET}"
    echo -e "  Fix perms (interactive):     ${C_GREEN}sudo $prog --fix-permissions --test${C_RESET}"
    echo -e "  Background restore:          ${C_GREEN}sudo $prog --background-restore latest /mnt/restore${C_RESET}"
    echo -e "  List snapshot contents:      ${C_GREEN}sudo $prog --ls latest /path/to/dir${C_RESET}"
    echo
    echo -e "${C_BOLD}${C_YELLOW}DEPENDENCIES:${C_RESET}"
    echo -e "  This script requires: ${C_GREEN}restic, curl, gpg, bzip2, less, jq, flock${C_RESET}"
    echo
    echo -e "Config: ${C_DIM}${CONFIG_FILE}${C_RESET}  Log: ${C_DIM}${LOG_FILE}${C_RESET}"
    echo
    echo -e "For full details, see the online documentation: \e]8;;${readme_url}\a${C_CYAN}README.md${C_RESET}\e]8;;\a"
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

handle_crash() {
    local exit_code=$?
    local line_num=$1
    log_message "FATAL: Script terminated unexpectedly on line $line_num with exit code $exit_code."
    send_notification "Backup Crashed: $HOSTNAME" "x" \
        "${NTFY_PRIORITY_FAILURE}" "failure" "Backup script terminated unexpectedly on line $line_num."
}

build_backup_command() {
    local cmd=(restic)
    cmd+=($(get_verbosity_flags))
    if [ -n "${SFTP_CONNECTIONS:-}" ]; then
        cmd+=(-o "sftp.connections=${SFTP_CONNECTIONS}")
    fi
    [ -n "${LIMIT_UPLOAD:-}" ] && cmd+=(--limit-upload "${LIMIT_UPLOAD}")
    cmd+=(backup)
    [ -n "${READ_CONCURRENCY:-}" ] && cmd+=(--read-concurrency "${READ_CONCURRENCY}")
    [ -n "${BACKUP_TAG:-}" ] && cmd+=(--tag "$BACKUP_TAG")
    [ -n "${COMPRESSION:-}" ] && cmd+=(--compression "$COMPRESSION")
    [ -n "${PACK_SIZE:-}" ] && cmd+=(--pack-size "$PACK_SIZE")
    [ "${ONE_FILE_SYSTEM:-false}" = "true" ] && cmd+=(--one-file-system)
    [ -n "${EXCLUDE_FILE:-}" ] && [ -f "$EXCLUDE_FILE" ] && cmd+=(--exclude-file "$EXCLUDE_FILE")
    [ -n "${EXCLUDE_TEMP_FILE:-}" ] && cmd+=(--exclude-file "$EXCLUDE_TEMP_FILE")
    cmd+=("${BACKUP_SOURCES[@]}")
    printf "%s\n" "${cmd[@]}"
}

run_diff() {
    echo -e "${C_BOLD}--- Generating Backup Summary ---${C_RESET}"
    log_message "Generating backup summary (diff)"
    local path_args=()
    for p in "${BACKUP_SOURCES[@]}"; do
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

run_ls() {
    local snapshot_id="latest"
    local -a filter_paths=()
    if [[ $# -gt 0 ]] && [[ "$1" != /* ]]; then
        snapshot_id="$1"
        shift 1
    fi
    if [ $# -gt 0 ]; then
        filter_paths=("$@")
    fi
    echo -e "${C_BOLD}--- Listing Contents of Snapshot: ${snapshot_id} ---${C_RESET}"
    log_message "Listing contents of snapshot ${snapshot_id}"
    local ls_cmd=(restic ls -l "$snapshot_id")
    if [ ${#filter_paths[@]} -gt 0 ]; then
        echo -e "${C_DIM}Filtering by path(s): ${filter_paths[*]}${C_RESET}"
        ls_cmd+=("${filter_paths[@]}")
    fi
    echo -e "${C_DIM}Displaying snapshot contents (use arrow keys to scroll, 'q' to quit)...${C_RESET}"
    if ! "${ls_cmd[@]}" | less -f; then
        echo -e "${C_RED}Error: Failed to list contents for snapshot '${snapshot_id}'. Please check the ID and paths.${C_RESET}" >&2
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

send_teams() {
    local title="$1"
    local status="$2"
    local message="$3"
    if [[ "${TEAMS_ENABLED:-false}" != "true" ]] || [ -z "${TEAMS_WEBHOOK_URL:-}" ]; then
        return 0
    fi
    local color
    case "$status" in
        success) color="good" ;;
        warning) color="warning" ;;
        failure) color="attention" ;;
        *) color="default" ;;
    esac
    local escaped_title
    escaped_title=$(echo "$title" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    local escaped_message
    escaped_message=$(echo "$message" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    local json_payload
    printf -v json_payload '{
      "type": "message",
      "attachments": [{
        "contentType": "application/vnd.microsoft.card.adaptive",
        "content": {
          "type": "AdaptiveCard",
          "version": "1.4",
          "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
          "body": [
            {
              "type": "TextBlock",
              "text": "%s",
              "weight": "bolder",
              "size": "large",
              "wrap": true,
              "color": "%s"
            },
            {
              "type": "TextBlock",
              "text": "%s",
              "wrap": true,
              "separator": true
            }
          ],
          "msteams": { "width": "full", "entities": [] }
        }
      }]
    }' "$escaped_title" "$color" "$escaped_message"
    curl -s --max-time 15 \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        "$TEAMS_WEBHOOK_URL" >/dev/null 2>>"$LOG_FILE"
}

send_slack() {
    local title="$1"
    local status="$2" 
    local message="$3"
    if [[ "${SLACK_ENABLED:-false}" != "true" ]] || [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
        return 0
    fi
    local color
    case "$status" in
        success) color="#36a64f" ;;
        warning) color="#ffa500" ;;
        failure) color="#d50200" ;;
        *) color="#808080" ;;
    esac
    local escaped_title=$(echo "$title" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    local escaped_message=$(echo "$message" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    local json_payload
    printf -v json_payload '{
        "attachments": [
            {
                "color": "%s",
                "blocks": [
                    {
                        "type": "header",
                        "text": {
                            "type": "plain_text",
                            "text": "%s"
                        }
                    },
                    {
                        "type": "section",
                        "text": {
                            "type": "mrkdwn",
                            "text": "%s"
                        }
                    }
                ]
            }
        ]
    }' "$color" "$escaped_title" "$escaped_message"
    curl -s --max-time 15 \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        "$SLACK_WEBHOOK_URL" >/dev/null 2>>"$LOG_FILE"
}

send_notification() {
    local title="$1"
    local tags="$2"
    local ntfy_priority="$3"
    local discord_status="$4"
    local message="$5"
    send_ntfy "$title" "$tags" "$ntfy_priority" "$message"
    send_discord "$title" "$discord_status" "$message"
    send_slack "$title" "$discord_status" "$message"
    send_teams "$title" "$discord_status" "$message"
}

setup_environment() {
    export RESTIC_REPOSITORY
    export RESTIC_PASSWORD_FILE

    if [ -n "${GOMAXPROCS_LIMIT:-}" ]; then
        export GOMAXPROCS="${GOMAXPROCS_LIMIT}"
    fi

    # Enable progress bar for interactive --verbose runs
    if [[ "${VERBOSE_MODE:-false}" == "true" ]] && [ -t 1 ]; then
        local fps_rate="${PROGRESS_FPS_RATE:-4}"
        export RESTIC_PROGRESS_FPS="${fps_rate}"
    fi

    if [ -n "${RESTIC_CACHE_DIR:-}" ]; then
        export RESTIC_CACHE_DIR
        mkdir -p "$RESTIC_CACHE_DIR"
    fi
    if [ -n "${EXCLUDE_PATTERNS:-}" ]; then
        EXCLUDE_TEMP_FILE=$(mktemp)
        echo "$EXCLUDE_PATTERNS" | tr ' ' '\n' > "$EXCLUDE_TEMP_FILE"
    fi
}

cleanup() {
    [ -n "${EXCLUDE_TEMP_FILE:-}" ] && rm -f "$EXCLUDE_TEMP_FILE"
    if [ -n "${LOCK_FD:-}" ]; then
        flock -u "$LOCK_FD"
    fi
}

run_preflight_checks() {
    local mode="${1:-backup}"
    local verbosity="${2:-quiet}"
    # Helper function for failure
    handle_failure() {
        local error_message="$1"
        local exit_code="${2:-1}"
        local notification_title="Pre-flight Check FAILED: $HOSTNAME"
        local full_error_message="ERROR: $error_message"
        log_message "$full_error_message"
        [[ "$verbosity" == "verbose" ]] && echo -e "[${C_RED} FAIL ${C_RESET}]"
        echo -e "${C_RED}$full_error_message${C_RESET}" >&2
        send_notification "$notification_title" "x" \
            "${NTFY_PRIORITY_FAILURE}" "failure" "$error_message"
        exit "$exit_code"
    }
    if [[ "$verbosity" == "verbose" ]]; then
        echo -e "${C_BOLD}--- Running Pre-flight Checks ---${C_RESET}"
    fi
    # System Dependencies
    if [[ "$verbosity" == "verbose" ]]; then
        echo -e "\n  ${C_DIM}- Checking System Dependencies${C_RESET}"
        printf "     %-65s" "Required commands (restic, curl, gpg, bzip2, less, flock, jq)..."
    fi
    local required_cmds=(restic curl flock jq less gpg bzip2)
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            local install_hint="On Debian-based systems, try: sudo apt install $cmd"
            case "$cmd" in
                gpg) install_hint="On Debian-based systems, try: sudo apt install gnupg";;
                bzip2) install_hint="On Debian-based systems, try: sudo apt install bzip2";;
                less) install_hint="On Debian-based systems, try: sudo apt install less";;
            esac
            handle_failure "Required command '$cmd' not found. $install_hint" "10"
        fi
    done
    if [[ "$verbosity" == "verbose" ]]; then echo -e "[${C_GREEN}  OK  ${C_RESET}]"; fi
    # --- Performance Settings Validation ---
    if [[ "$verbosity" == "verbose" ]]; then echo -e "\n  ${C_DIM}- Checking Performance Settings${C_RESET}"; fi
    local numeric_vars=("GOMAXPROCS_LIMIT" "LIMIT_THREADS" "LIMIT_UPLOAD" "SFTP_CONNECTIONS")
    for var in "${numeric_vars[@]}"; do
        local value="${!var:-}"
        if [[ -n "$value" ]]; then
            if [[ "$verbosity" == "verbose" ]]; then printf "    %-65s" "Validating ${var} ('${value}')..."; fi
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                handle_failure "${var} must be a positive integer, but got: '${value}'"
            fi
            if [[ "$verbosity" == "verbose" ]]; then echo -e "[${C_GREEN}  OK  ${C_RESET}]"; fi
        fi
    done
    # --- Config Files Existence & Permissions Check ---
    if [[ "$verbosity" == "verbose" ]]; then echo -e "\n  ${C_DIM}- Checking Configuration Files${C_RESET}"; fi
    if [[ "$verbosity" == "verbose" ]]; then printf "    %-65s" "Secure permissions on config file (600)..."; fi
    local perms
    perms=$(stat -c %a "$CONFIG_FILE" 2>/dev/null)
    if [[ "$perms" != "600" ]]; then
        echo -e "[${C_YELLOW} WARN ${C_RESET}]"
        echo -e "${C_YELLOW}    ⚠️  Configuration file has insecure permissions ($perms), should be 600.${C_RESET}"
        if [[ "${AUTO_FIX_PERMS}" == "true" ]]; then
            if chmod 600 "$CONFIG_FILE"; then
                echo -e "${C_GREEN}    ✅ Automatically corrected permissions to 600.${C_RESET}"
            else
                echo -e "${C_RED}    ❌ Failed to correct permissions.${C_RESET}"
            fi
        fi
    else
        if [[ "$verbosity" == "verbose" ]]; then echo -e "[${C_GREEN}  OK  ${C_RESET}]"; fi
    fi

    # --- Password File Existence & Permissions Check ---
    if [[ "$verbosity" == "verbose" ]]; then printf "    %-65s" "Password file ('$RESTIC_PASSWORD_FILE')..."; fi
    if [ ! -r "$RESTIC_PASSWORD_FILE" ]; then
        handle_failure "Password file not found or not readable: $RESTIC_PASSWORD_FILE" "11"
    fi
    perms=$(stat -c %a "$RESTIC_PASSWORD_FILE" 2>/dev/null)
    if [[ "$perms" != "400" ]]; then
        echo -e "[${C_YELLOW} WARN ${C_RESET}]"
        echo -e "${C_YELLOW}    ⚠️  Password file has insecure permissions ($perms), should be 400.${C_RESET}"
        if [[ "${AUTO_FIX_PERMS}" == "true" ]]; then
            if chmod 400 "$RESTIC_PASSWORD_FILE"; then
                echo -e "${C_GREEN}    ✅ Automatically corrected permissions to 400.${C_RESET}"
            else
                echo -e "${C_RED}    ❌ Failed to correct permissions.${C_RESET}"
            fi
        fi
    else
        if [[ "$verbosity" == "verbose" ]]; then echo -e "[${C_GREEN}  OK  ${C_RESET}]"; fi
    fi
    # --- Exclude File Check ---
    if [ -n "${EXCLUDE_FILE:-}" ]; then
        if [[ "$verbosity" == "verbose" ]]; then printf "    %-65s" "Exclude file ('$EXCLUDE_FILE')..."; fi
        if [ ! -r "$EXCLUDE_FILE" ]; then
            handle_failure "The specified EXCLUDE_FILE is not readable: ${EXCLUDE_FILE}" "14"
        fi
        if [[ "$verbosity" == "verbose" ]]; then echo -e "[${C_GREEN}  OK  ${C_RESET}]"; fi
    fi

    # --- Log File Check ---
    if [[ "$verbosity" == "verbose" ]]; then printf "    %-65s" "Log file writability ('$LOG_FILE')..."; fi
    if ! touch "$LOG_FILE" >/dev/null 2>&1; then
        handle_failure "The log file or its directory is not writable: ${LOG_FILE}" "15"
    fi
    if [[ "$verbosity" == "verbose" ]]; then echo -e "[${C_GREEN}  OK  ${C_RESET}]"; fi

    # Repository State
    if [[ "$verbosity" == "verbose" ]]; then echo -e "\n  ${C_DIM}- Checking Repository State${C_RESET}"; fi
    if [[ "$verbosity" == "verbose" ]]; then printf "    %-65s" "Repository connectivity and credentials..."; fi
    if ! restic cat config >/dev/null 2>&1; then
        if [[ "$mode" == "init" ]]; then
            if [[ "$verbosity" == "verbose" ]]; then echo -e "[${C_YELLOW} SKIP ${C_RESET}] (OK for --init mode)"; fi
            return 0
        fi
        handle_failure "Cannot access repository. Check credentials or run --init first." "12"
    fi
    if [[ "$verbosity" == "verbose" ]]; then echo -e "[${C_GREEN}  OK  ${C_RESET}]"; fi
    if [[ "$verbosity" == "verbose" ]]; then printf "    %-65s" "Stale repository locks..."; fi
    local lock_info
    lock_info=$(restic list locks 2>/dev/null || true)
    if [ -n "$lock_info" ]; then
        if [[ "$verbosity" == "verbose" ]]; then
            echo -e "[${C_YELLOW} WARN ${C_RESET}]"
            echo -e "${C_YELLOW}    ⚠️  Stale locks found! This may prevent backups from running.${C_RESET}"
            echo -e "${C_DIM}    Run the --unlock command to remove them.${C_RESET}"
        fi
    else
        if [[ "$verbosity" == "verbose" ]]; then echo -e "[${C_GREEN}  OK  ${C_RESET}]"; fi
    fi
    # Backup Sources
    if [[ "$mode" == "backup" || "$mode" == "diff" ]]; then
        if [[ "$verbosity" == "verbose" ]]; then echo -e "\n  ${C_DIM}- Checking Backup Sources${C_RESET}"; fi
        if ! declare -p BACKUP_SOURCES 2>/dev/null | grep -q "declare -a"; then
            handle_failure "Configuration Error: BACKUP_SOURCES is not a valid array. Example: BACKUP_SOURCES=('/path/one' '/path/two')"
        fi
        for source in "${BACKUP_SOURCES[@]}"; do
            if [[ "$verbosity" == "verbose" ]]; then printf "    %-65s" "Source directory ('$source')..."; fi
            if [ ! -d "$source" ] || [ ! -r "$source" ]; then
                handle_failure "Source directory not found or not readable: $source" "13"
            fi
            if [[ "$verbosity" == "verbose" ]]; then echo -e "[${C_GREEN}  OK  ${C_RESET}]"; fi
        done
    fi
    if [[ "$verbosity" == "quiet" ]]; then
        echo -e "${C_GREEN}✅ Pre-flight checks passed.${C_RESET}"
    fi
}

rotate_log() {
    if [ ! -f "$LOG_FILE" ]; then
        return 0
    fi
    local max_size_bytes=$(( ${MAX_LOG_SIZE_MB:-10} * 1024 * 1024 ))
    local log_size
    if command -v stat >/dev/null 2>&1; then
        log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    else
        log_size=0
    fi
    if [ "$log_size" -gt "$max_size_bytes" ]; then
        mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d_%H%M%S)"
        touch "$LOG_FILE"
        find "$(dirname "$LOG_FILE")" -name "$(basename "$LOG_FILE").*" \
            -type f -mtime +"${LOG_RETENTION_DAYS:-30}" -delete 2>/dev/null || true
    fi
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

run_install_scheduler() {
    echo -e "${C_BOLD}--- Backup Schedule Installation Wizard ---${C_RESET}"
    if [[ $EUID -ne 0 ]]; then
        echo -e "${C_RED}ERROR: This operation requires root privileges.${C_RESET}" >&2
        exit 1
    fi
    local script_path
    script_path=$(realpath "$0")
    echo -e "\n${C_YELLOW}Which scheduling system would you like to use?${C_RESET}"
    echo -e "  1) ${C_GREEN}systemd timer${C_RESET} (Modern, recommended, more flexible logging)"
    echo -e "  2) ${C_CYAN}crontab${C_RESET}       (Classic, simple, universally available)"
    local scheduler_choice
    read -p "Enter your choice [1]: " scheduler_choice
    scheduler_choice=${scheduler_choice:-1}
    echo -e "\n${C_YELLOW}How often would you like the backup to run?${C_RESET}"
    echo -e "  1) ${C_GREEN}Once daily${C_RESET}"
    echo -e "  2) ${C_GREEN}Twice daily${C_RESET} (e.g., every 12 hours)"
    echo -e "  3) ${C_CYAN}Custom schedule${C_RESET} (provide your own expression)"
    local schedule_choice
    read -p "Enter your choice [1]: " schedule_choice
    schedule_choice=${schedule_choice:-1}

    local systemd_schedule cron_schedule
    case "$schedule_choice" in
        1)
            local daily_time
            while true; do
                read -p "Enter the time to run the backup (24-hour HH:MM format) [03:00]: " daily_time
                daily_time=${daily_time:-03:00}
                if [[ "$daily_time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then break; else echo -e "${C_RED}Invalid format. Please use HH:MM.${C_RESET}"; fi
            done
            local hour=${daily_time%%:*} minute=${daily_time##*:}
            systemd_schedule="*-*-* ${hour}:${minute}:00"
            cron_schedule="${minute} ${hour} * * *"
            ;;
        2)
            local time1 time2
            while true; do
                read -p "Enter the first time (24-hour HH:MM format) [03:00]: " time1
                time1=${time1:-03:00}
                if [[ "$time1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then break; else echo -e "${C_RED}Invalid format. Please use HH:MM.${C_RESET}"; fi
            done
            while true; do
                read -p "Enter the second time (24-hour HH:MM format) [15:30]: " time2
                time2=${time2:-15:30}
                if [[ "$time2" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then break; else echo -e "${C_RED}Invalid format. Please use HH:MM.${C_RESET}"; fi
            done
            local hour1=${time1%%:*} min1=${time1##*:}
            local hour2=${time2%%:*} min2=${time2##*:}
            printf -v systemd_schedule "*-*-* %s:%s:00\n*-*-* %s:%s:00" "$hour1" "$min1" "$hour2" "$min2"
            printf -v cron_schedule "%s %s * * *\n%s %s * * *" "$min1" "$hour1" "$min2" "$hour2"
            ;;
        3)
            if [[ "$scheduler_choice" == "1" ]]; then
                read -p "Enter a custom systemd 'OnCalendar' expression: " systemd_schedule
                if command -v systemd-analyze >/dev/null && ! systemd-analyze calendar "$systemd_schedule" --iterations=1 >/dev/null 2>&1; then
                    echo -e "${C_RED}Warning: '$systemd_schedule' may be an invalid expression.${C_RESET}"
                fi
            else
                while true; do
                    read -p "Enter a custom cron expression (e.g., '0 4 * * *'): " cron_schedule
                    if echo "$cron_schedule" | grep -qE '^([0-9*,/-]+\s){4}[0-9*,/-]+$'; then
                        break
                    else
                        echo -e "${C_RED}Invalid format. A cron expression must have 5 fields separated by spaces, using only valid characters (0-9,*,/,-).${C_RESET}"
                    fi
                done
            fi
            ;;
        *)
            echo -e "${C_RED}Invalid choice. Aborting.${C_RESET}" >&2; return 1 ;;
    esac
    echo -e "\n${C_BOLD}--- Summary ---${C_RESET}"
    echo -e "  ${C_DIM}Script Path:${C_RESET} $script_path"
    echo -e "  ${C_DIM}Config File:${C_RESET} $CONFIG_FILE"
    if [[ "$scheduler_choice" == "1" ]]; then
        echo -e "  ${C_DIM}Scheduler:${C_RESET}   systemd timer"
        printf "  ${C_DIM}Schedule:%b\n%s${C_RESET}\n" "${C_RESET}" "$systemd_schedule"
        echo
        read -p "Proceed with installation? (y/n): " confirm
        if [[ "${confirm,,}" != "y" ]]; then echo "Aborted."; return 1; fi
        install_systemd_timer "$script_path" "$systemd_schedule" "$CONFIG_FILE"
    else
        echo -e "  ${C_DIM}Scheduler:${C_RESET}   crontab"
        printf "  ${C_DIM}Schedule:%b\n%s${C_RESET}\n" "${C_RESET}" "$cron_schedule"
        echo
        read -p "Proceed with installation? (y/n): " confirm
        if [[ "${confirm,,}" != "y" ]]; then echo "Aborted."; return 1; fi
        install_crontab "$script_path" "$cron_schedule" "$LOG_FILE"
    fi
}

install_systemd_timer() {
    local script_path="$1"
    local schedule="$2"
    local config_file="$3"
    local service_file="/etc/systemd/system/restic-backup.service"
    local timer_file="/etc/systemd/system/restic-backup.timer"

    if [ -f "$service_file" ] || [ -f "$timer_file" ]; then
        read -p "Existing systemd files found. Overwrite? (y/n): " confirm
        if [[ "${confirm,,}" != "y" ]]; then echo "Aborted."; return 1; fi
    fi
    echo "Creating systemd service file: $service_file"
    cat > "$service_file" << EOF
[Unit]
Description=Restic Backup Service
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$config_file
ExecStart=$script_path
User=root
Group=root
EOF

    echo "Creating systemd timer file: $timer_file"
    cat > "$timer_file" << EOF
[Unit]
Description=Run Restic Backup on a schedule

[Timer]
Persistent=true
EOF
    while IFS= read -r schedule_line; do
        if [ -n "$schedule_line" ]; then
            echo "OnCalendar=$schedule_line" >> "$timer_file"
        fi
    done <<< "$schedule"
    cat >> "$timer_file" << EOF

[Install]
WantedBy=timers.target
EOF

    echo "Reloading systemd daemon, enabling and starting timer..."
    if systemctl daemon-reload && systemctl enable --now restic-backup.timer; then
        echo -e "${C_GREEN}✅ systemd timer installed and activated successfully.${C_RESET}"
        echo -e "\n${C_BOLD}--- Verifying Status ---${C_RESET}"
        systemctl list-timers restic-backup.timer
    else
        echo -e "${C_RED}❌ Failed to install or start systemd timer.${C_RESET}" >&2
        return 1
    fi
}

install_crontab() {
    local script_path="$1"
    local schedule="$2"
    local log_file="$3"
    local cron_file="/etc/cron.d/restic-backup"
    if [ -f "$cron_file" ]; then
        echo -e "${C_YELLOW}Existing cron file found at $cron_file:${C_RESET}"
        cat "$cron_file"
        echo
        read -p "Add new schedule(s) to this file? (y/n): " confirm
        if [[ "${confirm,,}" != "y" ]]; then
            echo "Aborted."
            return 1
        fi
        echo "Appending new schedule(s)..."
        local new_jobs_added=0
        while IFS= read -r schedule_line; do
            if [ -n "$schedule_line" ]; then
                local full_command_line="$schedule_line root $script_path"
                if grep -qF "$full_command_line" "$cron_file"; then
                    echo -e "${C_DIM}Skipping duplicate schedule: $schedule_line${C_RESET}"
                else
                    echo "$full_command_line >> \"$log_file\" 2>&1" >> "$cron_file"
                    ((new_jobs_added++))
                fi
            fi
        done <<< "$schedule"
        if [ "$new_jobs_added" -eq 0 ]; then
            echo -e "${C_YELLOW}No new unique schedules were added.${C_RESET}"
        fi
    else
        echo "Creating new cron job file: $cron_file"
        cat > "$cron_file" << EOF
# Restic Backup Job installed by restic-backup.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

EOF

        while IFS= read -r schedule_line; do
            if [ -n "$schedule_line" ]; then
                echo "$schedule_line root $script_path >> \"$log_file\" 2>&1" >> "$cron_file"
            fi
        done <<< "$schedule"
    fi

    chmod 644 "$cron_file"
    echo -e "${C_GREEN}✅ Cron job file updated successfully.${C_RESET}"
    echo -e "\n${C_BOLD}--- Current Cron File Content ---${C_RESET}"
    cat "$cron_file"
}

run_uninstall_scheduler() {
    echo -e "${C_BOLD}--- Backup Schedule Uninstallation ---${C_RESET}"
    if [[ $EUID -ne 0 ]]; then
        echo -e "${C_RED}ERROR: This operation requires root privileges.${C_RESET}" >&2
        exit 1
    fi
    local service_file="/etc/systemd/system/restic-backup.service"
    local timer_file="/etc/systemd/system/restic-backup.timer"
    local cron_file="/etc/cron.d/restic-backup"
    local was_systemd=false
    local was_cron=false
    local -a files_to_remove=()
    if [ -f "$timer_file" ]; then
        was_systemd=true
        files_to_remove+=("$timer_file")
        [ -f "$service_file" ] && files_to_remove+=("$service_file")
    fi
    if [ -f "$cron_file" ]; then
        was_cron=true
        files_to_remove+=("$cron_file")
    fi
    if [ ${#files_to_remove[@]} -eq 0 ]; then
        echo -e "${C_YELLOW}No scheduled backup tasks found to uninstall.${C_RESET}"
        return 0
    fi
    echo -e "${C_YELLOW}The following scheduled task files will be PERMANENTLY removed:${C_RESET}"
    for file in "${files_to_remove[@]}"; do
        echo "  - $file"
    done
    echo
    read -p "Are you sure you want to proceed? (y/n): " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        echo "Aborted by user."
        return 0
    fi
    if [[ "$was_systemd" == "true" ]]; then
        echo "Stopping and disabling systemd timer..."
        systemctl stop restic-backup.timer >/dev/null 2>&1 || true
        systemctl disable restic-backup.timer >/dev/null 2>&1 || true
    fi
    echo "Removing files..."
    rm -f "${files_to_remove[@]}"
    if [[ "$was_systemd" == "true" ]]; then
        systemctl daemon-reload
        echo -e "${C_GREEN}✅ systemd timer and service files removed.${C_RESET}"
    fi
    if [[ "$was_cron" == "true" ]]; then
         echo -e "${C_GREEN}✅ Cron file removed.${C_RESET}"
    fi
}

get_verbosity_flags() {
    local effective_log_level="${LOG_LEVEL:-1}"
    if [[ "${VERBOSE_MODE:-}" == "true" ]]; then
        effective_log_level=2 # Force verbose level 2 when --verbose is used
    fi
    local flags=()
    [ "$effective_log_level" -le 0 ] && flags+=(--quiet)
    [ "$effective_log_level" -ge 2 ] && flags+=(--verbose)
    [ "$effective_log_level" -ge 3 ] && flags+=(--verbose)
    echo "${flags[@]}"
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

run_stats() {
    local exit_code=0
    echo -e "${C_BOLD}--- Displaying Repository Statistics ---${C_RESET}"
    echo -e "\n${C_CYAN}1. Logical Size (Total size of all unique files across all backups):${C_RESET}"
    log_message "Getting repository stats (restore-size)"
    if ! restic stats --mode restore-size; then
        log_message "ERROR: Failed to get restore-size stats"
        echo -e "${C_RED}❌ Failed to get restore-size stats.${C_RESET}" >&2
        exit_code=1
    fi
    echo -e "\n${C_CYAN}2. Physical Size (Actual space used on storage):${C_RESET}"
    log_message "Getting repository stats (raw-data)"
    if ! restic stats --mode raw-data; then
        log_message "ERROR: Failed to get raw-data stats"
        echo -e "${C_RED}❌ Failed to get raw-data stats.${C_RESET}" >&2
        exit_code=1
    fi
    if [ "$exit_code" -eq 0 ]; then
        echo -e "\n${C_GREEN}✅ Statistics displayed successfully.${C_RESET}"
        return 0
    else
        return 1
    fi
}

run_backup() {
    local start_time=$(date +%s)
    echo -e "${C_BOLD}--- Starting Backup ---${C_RESET}"
    log_message "Starting backup of: ${BACKUP_SOURCES[*]}"
    local backup_cmd=()
    mapfile -t backup_cmd < <(build_backup_command)
    local backup_log=$(mktemp)
    local backup_success=false
    if run_with_priority "${backup_cmd[@]}" 2>&1 | tee "$backup_log"; then
        backup_success=true
    fi
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
    local forget_cmd=(restic)
    forget_cmd+=($(get_verbosity_flags))
    forget_cmd+=(forget)
    [ -n "${KEEP_LAST:-}" ] && forget_cmd+=(--keep-last "$KEEP_LAST")
    [ -n "${KEEP_DAILY:-}" ] && forget_cmd+=(--keep-daily "$KEEP_DAILY")
    [ -n "${KEEP_WEEKLY:-}" ] && forget_cmd+=(--keep-weekly "$KEEP_WEEKLY")
    [ -n "${KEEP_MONTHLY:-}" ] && forget_cmd+=(--keep-monthly "$KEEP_MONTHLY")
    [ -n "${KEEP_YEARLY:-}" ] && forget_cmd+=(--keep-yearly "$KEEP_YEARLY")
    [ "${PRUNE_AFTER_FORGET:-true}" = "true" ] && forget_cmd+=(--prune)
    if run_with_priority "${forget_cmd[@]}" 2>&1 | tee -a "$LOG_FILE"; then
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

run_check_full() {
    echo -e "${C_BOLD}--- Checking Repository Integrity (Full Data Scan) ---${C_RESET}"
    echo -e "${C_YELLOW}⚠️  This will read ALL data and may be slow and consume significant bandwidth.${C_RESET}"
    log_message "Running FULL integrity check (--read-data)"
    if restic check --read-data 2>&1 | tee -a "$LOG_FILE"; then
        log_message "Full integrity check passed"
        echo -e "${C_GREEN}✅ Repository integrity OK (Full data scan complete).${C_RESET}"
    else
        log_message "CRITICAL: Full integrity check FAILED"
        echo -e "${C_RED}❌ CRITICAL: Full integrity check FAILED.${C_RESET}" >&2
        send_notification "Repository Check FAILED: $HOSTNAME" "x" \
            "${NTFY_PRIORITY_FAILURE}" "failure" "CRITICAL: A full repository integrity check (--read-data) has failed!"
    fi
}

run_restore() {
    echo -e "${C_BOLD}--- Restore Mode ---${C_RESET}"
    echo "Available snapshots:"
    restic snapshots --compact
    echo
    read -p "Enter snapshot ID to restore (or 'latest'): " snapshot_id
    if [ -z "$snapshot_id" ]; then
        echo "No snapshot specified, exiting"
        return 0
    fi
    local list_confirm
    read -p "Would you like to list the contents of this snapshot to find exact paths? (y/n): " list_confirm
    if [[ "${list_confirm,,}" == "y" || "${list_confirm,,}" == "yes" ]]; then
        echo -e "${C_DIM}Displaying snapshot contents (use arrow keys to scroll, 'q' to quit)...${C_RESET}"
        less -f <(restic ls -l "$snapshot_id")
    fi
    read -p "Enter restore destination (absolute path): " restore_dest
    if [[ -z "$restore_dest" || "$restore_dest" != /* ]]; then
        echo -e "${C_RED}Error: Must be a non-empty, absolute path. Aborting.${C_RESET}" >&2
        return 0
    fi
    #--- Dangerous Restore Confirmation ---
    local -a critical_dirs=("/" "/bin" "/boot" "/dev" "/etc" "/lib" "/lib64" "/proc" "/root" "/run" "/sbin" "/sys" "/usr" "/var/lib" "/var/log")
    if [[ -n "${ADDITIONAL_CRITICAL_DIRS:-}" ]]; then
        read -ra additional_dirs <<< "$ADDITIONAL_CRITICAL_DIRS"
        critical_dirs+=("${additional_dirs[@]}")
    fi
    local is_critical=false
    for dir in "${critical_dirs[@]}"; do
        if [[ "$restore_dest" == "$dir" || "$restore_dest" == "$dir"/* ]]; then
            is_critical=true
            break
        fi
    done
    if [[ "$is_critical" == "true" ]]; then
        echo -e "\n${C_RED}${C_BOLD}WARNING: Restoring to critical system directory '$restore_dest'${C_RESET}"
        echo -e "${C_RED}This could damage your system or make it unbootable!${C_RESET}"
        local confirm
        read -p "${C_YELLOW}Type 'DANGEROUS' to proceed or anything else to cancel: ${C_RESET}" confirm
        if [[ "$confirm" != "DANGEROUS" ]]; then
            echo -e "${C_GREEN}Restore cancelled for safety.${C_RESET}"
            return 0
        fi
        log_message "WARNING: User confirmed dangerous restore to: $restore_dest"
    fi
    local include_paths=()
    read -p "Optional: Enter specific file(s) to restore, separated by spaces (leave blank for full restore): " -a include_paths
    local restic_cmd=(restic restore "$snapshot_id" --target "$restore_dest" --verbose)
    if [ ${#include_paths[@]} -gt 0 ]; then
        for path in "${include_paths[@]}"; do
            restic_cmd+=(--include "$path")
        done
        echo -e "${C_YELLOW}Will restore only the specified paths...${C_RESET}"
    fi
    echo -e "${C_BOLD}\n--- Performing Dry Run (No changes will be made) ---${C_RESET}"
    if ! "${restic_cmd[@]}" --dry-run; then
        echo -e "${C_RED}❌ Dry run failed. Aborting restore.${C_RESET}" >&2
        return 1
    fi
    echo -e "${C_BOLD}--- Dry Run Complete ---${C_RESET}"
    local proceed_confirm
    read -p "Proceed with the actual restore? (y/n): " proceed_confirm
    if [[ "${proceed_confirm,,}" != "y" && "${proceed_confirm,,}" != "yes" ]]; then
        echo "Restore cancelled by user."
        return 0
    fi
    mkdir -p "$restore_dest"
    echo -e "${C_BOLD}--- Performing Restore ---${C_RESET}"
    log_message "Restoring snapshot $snapshot_id to $restore_dest"
    local restore_log
    restore_log=$(mktemp)
    local restore_success=false
    if "${restic_cmd[@]}" 2>&1 | tee "$restore_log"; then
        restore_success=true
    fi
    cat "$restore_log" >> "$LOG_FILE"
    if [ "$restore_success" = false ]; then
        log_message "ERROR: Restore failed"
        echo -e "${C_RED}❌ Restore failed${C_RESET}" >&2
        send_notification "Restore FAILED: $HOSTNAME" "x" \
            "${NTFY_PRIORITY_FAILURE}" "failure" "Failed to restore $snapshot_id"
        rm -f "$restore_log"
        return 1
    fi
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
        _handle_restore_ownership "$restore_dest"

        send_notification "Restore SUCCESS: $HOSTNAME" "white_check_mark" \
            "${NTFY_PRIORITY_SUCCESS}" "success" "Restored $snapshot_id to $restore_dest"
    fi
    rm -f "$restore_log"
}

_handle_restore_ownership() {
    local restore_dest="$1"

    if [[ "$restore_dest" == /home/* ]]; then
        local dest_user
        dest_user=$(stat -c %U "$(dirname "$restore_dest")" 2>/dev/null || echo "${restore_dest#/home/}" | cut -d/ -f1)

        if [[ -n "$dest_user" ]] && id -u "$dest_user" &>/dev/null; then
            log_message "Home directory detected. Setting ownership of restored files to '$dest_user'."
            if chown -R "${dest_user}:${dest_user}" "$restore_dest"; then
                log_message "Successfully changed ownership of $restore_dest to $dest_user"
            else
                log_message "WARNING: Failed to change ownership of $restore_dest to $dest_user. Please check permissions manually."
            fi
        fi
    fi
}

_run_restore_command() {
    local snapshot_id="$1"
    local restore_dest="$2"
    shift 2
    mkdir -p "$restore_dest"
    local restic_cmd=(restic)
    restic_cmd+=($(get_verbosity_flags))
    restic_cmd+=(restore "$snapshot_id" --target "$restore_dest")
    if [ $# -gt 0 ]; then
        for path in "$@"; do
            restic_cmd+=(--include "$path")
        done
    fi
    if run_with_priority "${restic_cmd[@]}"; then
        return 0
    else
        return 1
    fi
}

run_background_restore() {
    echo -e "${C_BOLD}--- Background Restore Mode ---${C_RESET}"
    local snapshot_id="${1:?--background-restore requires a snapshot ID}"
    local restore_dest="${2:?--background-restore requires a destination path}"
    if [[ "$snapshot_id" == "latest" ]]; then
        if ! restic snapshots --json | jq 'length > 0' | grep -q true; then
            echo -e "${C_RED}Error: No snapshots exist in the repository. Cannot restore 'latest'. Aborting.${C_RESET}" >&2
            exit 1
        fi
        snapshot_id=$(restic snapshots --latest 1 --json | jq -r '.[0].id')
    fi
    if [[ -z "$restore_dest" || "$restore_dest" != /* ]]; then
        echo -e "${C_RED}Error: Destination must be a non-empty, absolute path. Aborting.${C_RESET}" >&2
        exit 1
    fi
    local restore_log="/tmp/restic-restore-${snapshot_id:0:8}-$(date +%s).log"
    echo "Restore job started. Details will be logged to: ${restore_log}"
    log_message "Starting background restore of snapshot ${snapshot_id} to ${restore_dest}. See ${restore_log} for details."
    (
        local start_time=$(date +%s)
        if _run_restore_command "$@"; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            _handle_restore_ownership "$restore_dest"
            log_message "Background restore SUCCESS: ${snapshot_id} to ${restore_dest} in ${duration}s."
            local notification_message
            printf -v notification_message "Successfully restored snapshot %s to %s in %dm %ds." \
                "${snapshot_id:0:8}" "${restore_dest}" "$((duration / 60))" "$((duration % 60))"
            send_notification "Restore SUCCESS: $HOSTNAME" "white_check_mark" \
                "${NTFY_PRIORITY_SUCCESS}" "success" "$notification_message"
        else
            log_message "Background restore FAILED: ${snapshot_id} to ${restore_dest}."
            send_notification "Restore FAILED: $HOSTNAME" "x" \
                "${NTFY_PRIORITY_FAILURE}" "failure" "Failed to restore snapshot ${snapshot_id:0:8} to ${restore_dest}. Check log: ${restore_log}"
        fi
    ) > "$restore_log" 2>&1 &
    echo -e "${C_GREEN}✅ Restore job launched in the background. You will receive a notification upon completion.${C_RESET}"
}

run_sync_restore() {
    log_message "Starting synchronous restore."
    local restore_dest="$2"
    if _run_restore_command "$@"; then
        _handle_restore_ownership "$restore_dest"
        log_message "Sync-restore SUCCESS."
        send_notification "Sync Restore SUCCESS: $HOSTNAME" "white_check_mark" \
            "${NTFY_PRIORITY_SUCCESS}" "success" "Successfully completed synchronous restore."
        return 0
    else
        log_message "Sync-restore FAILED."
        send_notification "Sync Restore FAILED: $HOSTNAME" "x" \
            "${NTFY_PRIORITY_FAILURE}" "failure" "Synchronous restore failed. Check the logs for details."
        return 1
    fi
}

run_snapshots_delete() {
    echo -e "${C_BOLD}--- Interactively Delete Snapshots ---${C_RESET}"
    echo -e "${C_BOLD}${C_RED}WARNING: This operation is permanent and cannot be undone.${C_RESET}"
    echo
    echo "Available snapshots:"
    if ! restic snapshots --compact; then
        echo -e "${C_RED}❌ Could not list snapshots. Aborting.${C_RESET}" >&2
        return 1
    fi
    echo
    local -a ids_to_delete
    read -p "Enter snapshot ID(s) to delete, separated by spaces: " -a ids_to_delete
    if [ ${#ids_to_delete[@]} -eq 0 ]; then
        echo "No snapshot IDs entered. Aborting."
        return 0
    fi
    echo -e "\nYou have selected the following ${C_YELLOW}${#ids_to_delete[@]} snapshot(s)${C_RESET} for deletion:"
    for id in "${ids_to_delete[@]}"; do
        echo "  - $id"
    done
    echo
    read -p "Are you absolutely sure you want to PERMANENTLY delete these snapshots? (Type 'yes' to confirm): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Confirmation not received. Aborting deletion."
        return 0
    fi
    echo -e "${C_BOLD}--- Deleting Snapshots ---${C_RESET}"
    log_message "User initiated deletion of snapshots: ${ids_to_delete[*]}"
    if restic forget "${ids_to_delete[@]}"; then
        log_message "Successfully forgot snapshots: ${ids_to_delete[*]}"
        echo -e "${C_GREEN}✅ Snapshots successfully deleted.${C_RESET}"
    else
        log_message "ERROR: Failed to forget snapshots: ${ids_to_delete[*]}"
        echo -e "${C_RED}❌ Failed to delete snapshots.${C_RESET}" >&2
        return 1
    fi
    read -p "Would you like to run 'prune' now to reclaim disk space? (y/n): " prune_confirm
    if [[ "${prune_confirm,,}" == "y" || "${prune_confirm,,}" == "yes" ]]; then
        echo -e "${C_BOLD}--- Pruning Repository ---${C_RESET}"
        log_message "Running prune after manual forget"
        if run_with_priority restic prune; then
            log_message "Prune completed successfully."
            echo -e "${C_GREEN}✅ Repository pruned.${C_RESET}"
        else
            log_message "ERROR: Prune failed after manual forget."
            echo -e "${C_RED}❌ Prune failed.${C_RESET}" >&2
        fi
    else
        echo -e "${C_CYAN}ℹ️  Skipping prune. Run '--forget' or 'restic prune' later to reclaim space.${C_RESET}"
    fi
}

# =================================================================
# MAIN SCRIPT EXECUTION
# =================================================================

# 1. Parse flags.
VERBOSE_MODE=false
AUTO_FIX_PERMS=${AUTO_FIX_PERMS:-false}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose)
      VERBOSE_MODE=true
      shift
      ;;
    --fix-permissions)
      if ! [ -t 0 ]; then
        echo -e "${C_RED}ERROR: The --fix-permissions flag can only be used in an interactive session.${C_RESET}" >&2
        exit 1
      fi
      AUTO_FIX_PERMS=true
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

# 2. Set traps.
trap 'handle_crash $LINENO' ERR
trap cleanup EXIT

# 3. Acquire the lock.
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo -e "${C_RED}Another backup is already running${C_RESET}" >&2
    exit 5
fi
LOCK_FD=200

# 4. After lock, it's safe to run updates.
check_for_script_update
check_and_install_restic

# 5. Prepare the environment and run final pre-flight checks.
setup_environment
rotate_log

# Handle the --fix-permissions and AUTO_FIX_PERMS config for non-interactive mode
if [[ "${AUTO_FIX_PERMS}" == "true" ]]; then
    if ! [ -t 1 ]; then
        log_message "AUTO_FIX_PERMS=true ignored in non-interactive mode for safety."
        echo -e "${C_YELLOW}WARNING: AUTO_FIX_PERMS is enabled but ignored in non-interactive mode for safety.${C_RESET}"
        AUTO_FIX_PERMS=false
    fi
fi

# 6. Execute the requested command.
case "${1:-}" in
    --install-scheduler)
        run_install_scheduler
        ;;
    --uninstall-scheduler)
        run_uninstall_scheduler
        ;;
    --init)
        run_preflight_checks "init" "quiet"
        init_repository
        ;;
    --dry-run)
        echo -e "${C_BOLD}--- Dry Run Mode ---${C_RESET}"
        run_preflight_checks "backup" "quiet"
        backup_cmd=()
        mapfile -t backup_cmd < <(build_backup_command)
        backup_cmd+=(--dry-run)
        run_with_priority "${backup_cmd[@]}"
        ;;
    --test)
        echo -e "${C_BOLD}--- Test Mode ---${C_RESET}"
        run_preflight_checks "backup" "verbose"
        echo -e "${C_GREEN}✅ All tests passed${C_RESET}"
        ;;
    --snapshots)
        run_preflight_checks "backup" "quiet"
        run_snapshots
        ;;
    --ls)
        run_preflight_checks "backup" "quiet"
        shift
        run_ls "$@"
        ;;
    --restore)
        run_preflight_checks "restore" "quiet"
        run_restore
        ;;
    --background-restore)
        shift
        run_preflight_checks "restore" "quiet"
        run_background_restore "$@"
        ;;
    --sync-restore)
        shift
        run_preflight_checks "restore" "quiet"
        log_message "=== Starting sync-restore run ==="
        restore_exit_code=0
        if ! run_sync_restore "$@"; then
            restore_exit_code=1
        fi
        log_message "=== Sync-restore run completed ==="
        # --- Ping Healthchecks.io (Success or Failure) ---
        if [ "$restore_exit_code" -eq 0 ] && [[ -n "${HEALTHCHECKS_URL:-}" ]]; then
            curl -fsS -m 15 --retry 3 "${HEALTHCHECKS_URL}" >/dev/null 2>>"$LOG_FILE"
        elif [ "$restore_exit_code" -ne 0 ] && [[ -n "${HEALTHCHECKS_URL:-}" ]]; then
            curl -fsS -m 15 --retry 3 "${HEALTHCHECKS_URL}/fail" >/dev/null 2>>"$LOG_FILE"
        fi
        exit "$restore_exit_code"
        ;;
    --check)
        run_preflight_checks "backup" "quiet"
        run_check
        ;;
    --check-full)
        run_preflight_checks "backup" "quiet"
        run_check_full
        ;;
    --forget)
        run_preflight_checks "backup" "quiet"
        run_forget
        ;;
    --diff)
        run_preflight_checks "diff" "quiet"
        run_diff
        ;;
    --snapshots-delete)
        run_preflight_checks "backup" "quiet"
        run_snapshots_delete
        ;;
    --stats)
        run_preflight_checks "backup" "quiet"
        run_stats
        ;;
    --unlock)
        run_preflight_checks "unlock" "quiet"
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
        run_preflight_checks "backup" "quiet"
        log_message "=== Starting backup run ==="

        backup_exit_code=0
        if ! run_backup; then
            backup_exit_code=1
        fi

        if [ "$backup_exit_code" -eq 0 ]; then
            run_forget
            if [ "${CHECK_AFTER_BACKUP:-false}" = "true" ]; then
                run_check
            fi
        fi

        log_message "=== Backup run completed ==="

        # --- Ping Healthchecks.io (Success or Failure) ---
        if [ "$backup_exit_code" -eq 0 ] && [[ -n "${HEALTHCHECKS_URL:-}" ]]; then
            log_message "Pinging Healthchecks.io to signal successful run."
            if ! curl -fsS -m 15 --retry 3 "${HEALTHCHECKS_URL}" >/dev/null 2>>"$LOG_FILE"; then
                log_message "WARNING: Healthchecks.io success ping failed."
                send_notification "Healthchecks Ping Failed: $HOSTNAME" "warning" \
                    "${NTFY_PRIORITY_WARNING}" "warning" "Failed to ping Healthchecks.io after successful backup."
            fi
        elif [ "$backup_exit_code" -ne 0 ] && [[ -n "${HEALTHCHECKS_URL:-}" ]]; then
            log_message "Pinging Healthchecks.io with failure signal."
            if ! curl -fsS -m 15 --retry 3 "${HEALTHCHECKS_URL}/fail" >/dev/null 2>>"$LOG_FILE"; then
                log_message "WARNING: Healthchecks.io failure ping failed."
                send_notification "Healthchecks Ping Failed: $HOSTNAME" "warning" \
                    "${NTFY_PRIORITY_WARNING}" "warning" "Failed to ping Healthchecks.io /fail endpoint after backup failure."
            fi
        fi

        # Exit with the correct code to signal success or failure to the scheduler
        if [ "$backup_exit_code" -ne 0 ]; then
            exit "$backup_exit_code"
        fi
        ;;
esac

echo -e "${C_BOLD}--- Backup Script Completed ---${C_RESET}"
