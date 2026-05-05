#!/bin/bash

################################################################################
# Bastion Disk Cleanup Script
# Description: Clean up unnecessary files in home, /var, and safe /usr targets
# Created: 2025-12-05
# Usage: ./bastion-disk-clenup.sh [--dry-run]
################################################################################

set -e

SCRIPT_ON_HOST="${OPENCLAW_DISK_CLEANUP_SCRIPT:-/app/openclaw-docker/cronjobs/bastion-disk-clenup.sh}"
BASTION_RUN="${OPENCLAW_BASTION_RUN:-bastion-run}"

if [ "${OPENCLAW_DISK_CLEANUP_HOST_MODE:-0}" != "1" ] \
    && [ -d /host/app/openclaw-docker ] \
    && command -v "$BASTION_RUN" >/dev/null 2>&1; then
    exec "$BASTION_RUN" env OPENCLAW_DISK_CLEANUP_HOST_MODE=1 bash "$SCRIPT_ON_HOST" "$@"
fi

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Dry run mode
DRY_RUN=false
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=true
    echo -e "${YELLOW}[DRY RUN MODE] No files will actually be deleted${NC}"
    echo ""
fi

# Function to print section headers
print_header() {
    echo ""
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================${NC}"
}

# Function to print success messages
print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Function to print info messages
print_info() {
    echo -e "${YELLOW}→${NC} $1"
}

# Function to print error messages
print_error() {
    echo -e "${RED}✗${NC} $1"
}

ROOT_CMD=()
if [ "$(id -u)" -ne 0 ]; then
    if sudo -n true 2>/dev/null; then
        ROOT_CMD=(sudo -n)
    else
        print_error "Root privileges are required for system cleanup. Run with sudo or passwordless sudo."
        exit 1
    fi
fi

# Function to get directory size
get_dir_size() {
    du -sh "$1" 2>/dev/null | cut -f1 || echo "0"
}

get_system_path_size() {
    "${ROOT_CMD[@]}" du -sh "$1" 2>/dev/null | cut -f1 || echo "0"
}

# Function to show top-level home usage without including . or ..
show_top_home_usage() {
    find "$HOME" -maxdepth 1 -mindepth 1 -exec du -sh {} + 2>/dev/null | sort -hr | head -10
}

show_system_usage() {
    df -hT / 2>/dev/null || true
    echo ""
    "${ROOT_CMD[@]}" du -xhd1 /var /usr 2>/dev/null | sort -h | tail -20 || true
}

run_root_command() {
    local description="$1"
    shift

    print_info "$description"
    if [ "$DRY_RUN" = false ]; then
        if "${ROOT_CMD[@]}" "$@"; then
            print_success "$description"
        else
            print_error "Failed: $description"
            return 1
        fi
    else
        print_info "[DRY RUN] Would run: ${ROOT_CMD[*]} $*"
    fi
}

safe_remove_system_path() {
    local path="$1"
    local description="$2"

    if [ -e "$path" ] || [ -L "$path" ]; then
        local size
        size=$(get_system_path_size "$path")
        print_info "Removing: $description ($size)"

        if [ "$DRY_RUN" = false ]; then
            if "${ROOT_CMD[@]}" rm -rf -- "$path" 2>/dev/null; then
                print_success "Removed: $description"
            else
                print_error "Failed to remove: $description"
            fi
        else
            print_info "[DRY RUN] Would remove: $description"
        fi
    fi
}

safe_remove_system_contents() {
    local path="$1"
    local description="$2"

    if [ -d "$path" ]; then
        local size
        local count
        size=$(get_system_path_size "$path")
        count=$("${ROOT_CMD[@]}" find "$path" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)

        if [ "$count" -gt 0 ]; then
            print_info "Removing contents: $description ($size, $count entries)"

            if [ "$DRY_RUN" = false ]; then
                "${ROOT_CMD[@]}" find "$path" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
                print_success "Removed contents: $description"
            else
                print_info "[DRY RUN] Would remove $count entries from: $description"
            fi
        fi
    fi
}

clean_docker_cache() {
    if ! command -v docker >/dev/null 2>&1; then
        print_info "docker command not found; skipping Docker cleanup"
        return
    fi

    print_info "Docker usage before cleanup:"
    "${ROOT_CMD[@]}" docker system df 2>/dev/null || true

    if [ "$DRY_RUN" = false ]; then
        print_info "Pruning Docker build cache..."
        "${ROOT_CMD[@]}" docker builder prune --all --force 2>/dev/null || true
        print_success "Docker build cache pruned"

        print_info "Pruning unused Docker images..."
        "${ROOT_CMD[@]}" docker image prune --all --force 2>/dev/null || true
        print_success "Unused Docker images pruned"
    else
        print_info "[DRY RUN] Would run: docker builder prune --all --force"
        print_info "[DRY RUN] Would run: docker image prune --all --force"
    fi

    print_info "Docker usage after cleanup:"
    "${ROOT_CMD[@]}" docker system df 2>/dev/null || true
}

clean_rotated_xrdp_logs() {
    local days="${XRDP_LOG_RETENTION_DAYS:-7}"
    local count
    count=$("${ROOT_CMD[@]}" find /var/log -xdev -maxdepth 1 -type f \
        \( -name 'xrdp.log-*' -o -name 'xrdp-sesman.log-*' \) \
        -mtime +"$days" 2>/dev/null | wc -l)

    if [ "$count" -gt 0 ]; then
        print_info "Removing rotated XRDP logs older than $days days ($count files)"
        if [ "$DRY_RUN" = false ]; then
            "${ROOT_CMD[@]}" find /var/log -xdev -maxdepth 1 -type f \
                \( -name 'xrdp.log-*' -o -name 'xrdp-sesman.log-*' \) \
                -mtime +"$days" -delete 2>/dev/null || true
            print_success "Rotated XRDP logs removed"
        else
            print_info "[DRY RUN] Would remove $count rotated XRDP log files"
        fi
    fi
}

clean_system_coredumps() {
    local count
    count=$("${ROOT_CMD[@]}" find /var/lib/systemd/coredump -xdev -type f -name 'core.*' 2>/dev/null | wc -l)

    if [ "$count" -gt 0 ]; then
        print_info "Removing system coredumps ($count files)"
        if [ "$DRY_RUN" = false ]; then
            if command -v coredumpctl >/dev/null 2>&1; then
                "${ROOT_CMD[@]}" coredumpctl --vacuum-size=1M 2>/dev/null || true
            fi
            "${ROOT_CMD[@]}" find /var/lib/systemd/coredump -xdev -type f -name 'core.*' -delete 2>/dev/null || true
            print_success "System coredumps removed"
        else
            print_info "[DRY RUN] Would remove $count coredump files"
        fi
    fi
}

clean_old_installonly_packages() {
    if ! command -v dnf >/dev/null 2>&1; then
        print_info "dnf command not found; skipping old kernel cleanup"
        return
    fi

    local running_kernel
    running_kernel="$(uname -r)"
    local old_packages=()
    mapfile -t old_packages < <("${ROOT_CMD[@]}" dnf repoquery --installonly --latest-limit=-2 -q 2>/dev/null | grep -Fv -- "$running_kernel" || true)

    if [ "${#old_packages[@]}" -eq 0 ]; then
        print_info "No removable old installonly packages found"
        return
    fi

    print_info "Removing old installonly packages while preserving the newest 2 kernels and running kernel: $running_kernel"
    printf '%s\n' "${old_packages[@]}"

    if [ "$DRY_RUN" = false ]; then
        "${ROOT_CMD[@]}" dnf -y remove "${old_packages[@]}" || true
        print_success "Old installonly packages processed"
    else
        print_info "[DRY RUN] Would remove ${#old_packages[@]} old installonly packages"
    fi
}

clean_empty_kernel_module_dirs() {
    local count
    count=$("${ROOT_CMD[@]}" find /usr/lib/modules -xdev -maxdepth 1 -mindepth 1 -type d -empty 2>/dev/null | wc -l)

    if [ "$count" -gt 0 ]; then
        print_info "Removing empty kernel module directories ($count directories)"
        if [ "$DRY_RUN" = false ]; then
            "${ROOT_CMD[@]}" find /usr/lib/modules -xdev -maxdepth 1 -mindepth 1 -type d -empty -delete 2>/dev/null || true
            print_success "Empty kernel module directories removed"
        else
            print_info "[DRY RUN] Would remove $count empty kernel module directories"
        fi
    fi
}

clean_optional_local_tools() {
    if [ "${CLEAN_LOCAL_TOOLS:-0}" != "1" ]; then
        print_info "Skipping /usr/local tool removal. Set CLEAN_LOCAL_TOOLS=1 to remove optional manually installed tools."
        return
    fi

    local paths=(
        /usr/local/aws-cli
        /usr/local/bin/aws
        /usr/local/bin/aws_completer
        /usr/local/bin/kubectl
        /usr/local/bin/kubectx
        /usr/local/bin/kubens
        /usr/local/bin/helm
        /usr/local/bin/yq
        /usr/local/bin/fn
        /usr/local/bin/spf
        /usr/local/bin/btm
        /usr/local/bin/btop
        /usr/local/lib/node_modules/oh-my-logo
        /usr/local/bin/oh-my-logo
    )

    local path
    for path in "${paths[@]}"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            if rpm -qf "$path" >/dev/null 2>&1; then
                print_info "Skipping RPM-owned path: $path"
            else
                safe_remove_system_path "$path" "optional /usr/local tool: $path"
            fi
        fi
    done
}

# Function to safely remove files/directories
safe_remove() {
    local path="$1"
    local description="$2"

    if [ -e "$path" ] || [ -L "$path" ]; then
        local size=$(get_dir_size "$path")
        print_info "Removing: $description ($size)"

        if [ "$DRY_RUN" = false ]; then
            if rm -rf -- "$path" 2>/dev/null || "${ROOT_CMD[@]}" rm -rf -- "$path" 2>/dev/null; then
                print_success "Removed: $description"
            else
                print_error "Failed to remove: $description"
            fi
        else
            print_info "[DRY RUN] Would remove: $description"
        fi
    fi
}

# Function to safely remove only the contents of a directory
safe_remove_contents() {
    local path="$1"
    local description="$2"

    if [ -d "$path" ]; then
        local size=$(get_dir_size "$path")
        local count=$(find "$path" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)

        if [ "$count" -gt 0 ]; then
            print_info "Removing contents: $description ($size)"

            if [ "$DRY_RUN" = false ]; then
                if find "$path" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null \
                    || "${ROOT_CMD[@]}" find "$path" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; then
                    print_success "Removed contents: $description"
                else
                    print_error "Failed to remove all contents: $description"
                fi
            else
                print_info "[DRY RUN] Would remove $count entries from: $description"
            fi
        fi
    fi
}

# Function to remove matching files with find
safe_find_remove_files() {
    local description="$1"
    shift
    local count
    count=$(find "$HOME" "$@" -type f 2>/dev/null | wc -l)

    if [ "$count" -gt 0 ]; then
        print_info "Removing: $description ($count files)"

        if [ "$DRY_RUN" = false ]; then
            if find "$HOME" "$@" -type f -delete 2>/dev/null \
                || "${ROOT_CMD[@]}" find "$HOME" "$@" -type f -delete 2>/dev/null; then
                print_success "Removed: $description"
            else
                print_error "Failed to remove all files: $description"
            fi
        else
            print_info "[DRY RUN] Would remove $count files: $description"
        fi
    fi
}

# Function to remove matching directories with find
safe_find_remove_dirs() {
    local description="$1"
    shift
    local count
    count=$(find "$HOME" "$@" -type d 2>/dev/null | wc -l)

    if [ "$count" -gt 0 ]; then
        print_info "Removing: $description ($count directories)"

        if [ "$DRY_RUN" = false ]; then
            if find "$HOME" "$@" -type d -prune -exec rm -rf {} + 2>/dev/null \
                || "${ROOT_CMD[@]}" find "$HOME" "$@" -type d -prune -exec rm -rf {} + 2>/dev/null; then
                print_success "Removed: $description"
            else
                print_error "Failed to remove all directories: $description"
            fi
        else
            print_info "[DRY RUN] Would remove $count directories: $description"
        fi
    fi
}

print_header "Home Directory Cleanup Started"
echo "User: $USER"
echo "Home: $HOME"
echo "Date: $(date)"

# Show initial disk usage
print_header "Initial Home Directory Status"
echo "Top 10 largest items in home directory:"
show_top_home_usage
echo ""
echo "Total home directory size: $(get_dir_size $HOME)"

print_header "Initial System Disk Status"
show_system_usage

# 1. Clean cache directories
print_header "Cleaning Cache Directories"

safe_remove_contents "$HOME/.cache/pnpm" "pnpm metadata cache"
safe_remove_contents "$HOME/.cache/Homebrew" "Homebrew cache"
safe_remove_contents "$HOME/.cache/helm" "Helm repository cache"
safe_remove_contents "$HOME/.cache/node" "Node/Corepack cache"
safe_remove_contents "$HOME/.cache/pip" "pip cache"
safe_remove_contents "$HOME/.cache/node-gyp" "node-gyp cache"
safe_remove_contents "$HOME/.cache/gh" "GitHub CLI HTTP cache"
safe_remove_contents "$HOME/.cache/mozilla" "Mozilla browser cache"
safe_remove_contents "$HOME/.cache/mesa_shader_cache" "Mesa shader cache"
safe_remove_contents "$HOME/.cache/fontconfig" "fontconfig cache"
safe_remove_contents "$HOME/.cache/gstreamer-1.0" "GStreamer cache"
safe_remove_contents "$HOME/.cache/claude-cli-nodejs" "Claude CLI cache/log cache"
safe_remove_contents "$HOME/.cache/Microsoft" "Microsoft developer tool cache"
safe_remove "$HOME/.npm/_cacache" "npm cache"
safe_remove "$HOME/.npm/_npx" "npx temporary packages"
safe_remove "$HOME/.npm/_logs" "npm logs"
safe_remove_contents "$HOME/.nvm/.cache" "nvm download cache"
safe_remove_contents "$HOME/.kube/cache" "kubectl discovery/http cache"

if command -v npm &> /dev/null && [ "$DRY_RUN" = false ]; then
    print_info "Running npm cache clean..."
    npm cache clean --force 2>&1 | grep -v "^$" || true
    print_success "npm cache cleaned"
elif [ "$DRY_RUN" = true ]; then
    print_info "[DRY RUN] Would run: npm cache clean --force"
fi

# 1-1. Clean tool-specific temporary data
print_header "Cleaning Tool Temporary Data"
safe_remove_contents "$HOME/.codex/.tmp" "Codex temporary plugins/work files"
safe_remove_contents "$HOME/.codex/log" "Codex logs"
safe_remove_contents "$HOME/.claude/cache" "Claude cache"
safe_remove_contents "$HOME/.claude/telemetry" "Claude telemetry cache"
safe_remove_contents "$HOME/.claude/paste-cache" "Claude paste cache"
safe_remove_contents "$HOME/.claude/shell-snapshots" "Claude shell snapshots"
safe_remove_contents "$HOME/.codex-mdfy/logs" "codex-mdfy logs"
safe_remove "$HOME/.local/state/k9s/k9s.log" "k9s log"
safe_remove "$HOME/.local/state/btop.log" "btop log"
safe_remove "$HOME/.local/state/superfile/superfile.log" "superfile log"

# 2. Clean zsh completion dump files
print_header "Cleaning ZSH Completion Files"
for file in $HOME/.zcompdump*; do
    if [ -f "$file" ]; then
        safe_remove "$file" "ZSH completion dump: $(basename $file)"
    fi
done

# 3. Clean backup files
print_header "Cleaning Backup Files"
safe_remove "$HOME/.zshrc.backup" ".zshrc.backup"
safe_remove "$HOME/.bashrc.backup" ".bashrc.backup"
safe_remove "$HOME/.claude.json.backup" ".claude.json.backup"
safe_remove "$HOME/.zshrc.pre-oh-my-zsh" ".zshrc.pre-oh-my-zsh"
safe_remove "$HOME/.shell.pre-oh-my-zsh" ".shell.pre-oh-my-zsh"

# Find and remove other backup files
print_info "Searching for other backup files (*~, *.bak)..."
if [ "$DRY_RUN" = false ]; then
    if find "$HOME" -maxdepth 2 -type f \( -name "*~" -o -name "*.bak" \) -exec rm -f {} \; 2>/dev/null \
        || "${ROOT_CMD[@]}" find "$HOME" -maxdepth 2 -type f \( -name "*~" -o -name "*.bak" \) -exec rm -f {} \; 2>/dev/null; then
        print_success "Other backup files cleaned"
    else
        print_error "Failed to remove all backup files"
    fi
else
    backup_files=$(find "$HOME" -maxdepth 2 -type f \( -name "*~" -o -name "*.bak" \) 2>/dev/null | wc -l)
    print_info "[DRY RUN] Would remove $backup_files backup files"
fi

# 4. Clean Downloads directory
print_header "Cleaning Downloads Directory"
if [ -d "$HOME/Downloads" ]; then
    print_info "Downloads directory contents:"
    ls -lh "$HOME/Downloads" 2>/dev/null | tail -n +2 || echo "Empty"

    # Remove RPM files (usually installed packages)
    if ls "$HOME"/Downloads/*.rpm 1> /dev/null 2>&1; then
        print_info "Found RPM files in Downloads"
        if [ "$DRY_RUN" = false ]; then
            if rm -f "$HOME"/Downloads/*.rpm 2>/dev/null || "${ROOT_CMD[@]}" rm -f "$HOME"/Downloads/*.rpm 2>/dev/null; then
                print_success "RPM files removed from Downloads"
            else
                print_error "Failed to remove RPM files from Downloads"
            fi
        else
            rpm_count=$(ls "$HOME"/Downloads/*.rpm 2>/dev/null | wc -l)
            print_info "[DRY RUN] Would remove $rpm_count RPM files"
        fi
    fi

    # Remove DEB files (usually installed packages)
    if ls "$HOME"/Downloads/*.deb 1> /dev/null 2>&1; then
        print_info "Found DEB files in Downloads"
        if [ "$DRY_RUN" = false ]; then
            if rm -f "$HOME"/Downloads/*.deb 2>/dev/null || "${ROOT_CMD[@]}" rm -f "$HOME"/Downloads/*.deb 2>/dev/null; then
                print_success "DEB files removed from Downloads"
            else
                print_error "Failed to remove DEB files from Downloads"
            fi
        else
            deb_count=$(ls "$HOME"/Downloads/*.deb 2>/dev/null | wc -l)
            print_info "[DRY RUN] Would remove $deb_count DEB files"
        fi
    fi
fi

# 5. Remove empty directories
print_header "Removing Empty Directories"
empty_dirs=("Desktop" "Documents" "Music" "Pictures" "Public" "Templates" "Videos" "thinclient_drives")

for dir in "${empty_dirs[@]}"; do
    if [ -d "$HOME/$dir" ] && [ -z "$(ls -A "$HOME/$dir" 2>/dev/null)" ]; then
        if [ "$DRY_RUN" = false ]; then
            rmdir "$HOME/$dir" 2>/dev/null && print_success "Removed empty directory: $dir" || true
        else
            print_info "[DRY RUN] Would remove empty directory: $dir"
        fi
    fi
done

# 6. Clean old log files in home directory
print_header "Cleaning Old Log Files"
print_info "Searching for old log files (older than 30 days)..."
if [ "$DRY_RUN" = false ]; then
    if find "$HOME" -maxdepth 3 -type f -name "*.log" -mtime +30 -exec rm -f {} \; 2>/dev/null \
        || "${ROOT_CMD[@]}" find "$HOME" -maxdepth 3 -type f -name "*.log" -mtime +30 -exec rm -f {} \; 2>/dev/null; then
        print_success "Old log files cleaned"
    else
        print_error "Failed to remove all old log files"
    fi
else
    old_logs=$(find "$HOME" -maxdepth 3 -type f -name "*.log" -mtime +30 2>/dev/null | wc -l)
    print_info "[DRY RUN] Would remove $old_logs old log files"
fi

# 7. Clean Python bytecode caches
print_header "Cleaning Python Bytecode Caches"
safe_find_remove_dirs "Python __pycache__ directories" -name "__pycache__"

# 8. Clean VS Code Server caches
print_header "Cleaning VS Code Server Caches"
safe_remove_contents "$HOME/.vscode-server/data/logs" "VS Code Server logs"
safe_remove_contents "$HOME/.vscode-server/data/CachedExtensionVSIXs" "VS Code cached extension VSIXs"
safe_remove_contents "$HOME/.vscode-server/data/clp" "VS Code command line process cache"
safe_remove_contents "$HOME/.vscode-server/data/User/History" "VS Code local file history"
safe_find_remove_files "VS Code CLI logs" -path "$HOME/.vscode-server/.cli.*.log"

if [ -d "$HOME/.vscode-server/cli/servers" ]; then
    latest_server=$(find "$HOME/.vscode-server/cli/servers" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
    if [ -n "$latest_server" ]; then
        print_info "Keeping latest VS Code server: $(basename "$latest_server")"
        if [ "$DRY_RUN" = false ]; then
            if find "$HOME/.vscode-server/cli/servers" -maxdepth 1 -mindepth 1 -type d ! -path "$latest_server" -exec rm -rf {} + 2>/dev/null \
                || "${ROOT_CMD[@]}" find "$HOME/.vscode-server/cli/servers" -maxdepth 1 -mindepth 1 -type d ! -path "$latest_server" -exec rm -rf {} + 2>/dev/null; then
                print_success "Old VS Code server runtimes removed"
            else
                print_error "Failed to remove all old VS Code server runtimes"
            fi
        else
            old_servers=$(find "$HOME/.vscode-server/cli/servers" -maxdepth 1 -mindepth 1 -type d ! -path "$latest_server" 2>/dev/null | wc -l)
            print_info "[DRY RUN] Would remove $old_servers old VS Code server runtimes"
        fi
    fi
fi

# 9. Clean temporary files
print_header "Cleaning Temporary Files"
safe_remove "$HOME/.wget-hsts.old" "wget history backup"
safe_remove "$HOME/.lesshst.old" "less history backup"
safe_remove "$HOME/wget-log" "wget log"

# 10. Clean safe system-level disk targets found on bastion
print_header "Cleaning System Package Caches"
run_root_command "Running dnf clean all" dnf clean all || true
safe_remove_system_contents "/var/cache/PackageKit" "PackageKit cache"

print_header "Cleaning Docker Cache"
clean_docker_cache

print_header "Cleaning System Logs"
clean_rotated_xrdp_logs
run_root_command "Vacuuming systemd journal to 50M" journalctl --vacuum-size=50M || true

print_header "Cleaning System Coredumps"
clean_system_coredumps

print_header "Cleaning Old Kernel Packages"
clean_old_installonly_packages
clean_empty_kernel_module_dirs

print_header "Optional /usr/local Tool Cleanup"
clean_optional_local_tools

# Show final status
print_header "Final Home Directory Status"
echo "Top 10 largest items in home directory:"
show_top_home_usage
echo ""
echo "Total home directory size: $(get_dir_size $HOME)"

print_header "Final System Disk Status"
show_system_usage

print_header "Cleanup Completed!"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}This was a dry run. Run without --dry-run to actually remove files.${NC}"
fi
echo ""
