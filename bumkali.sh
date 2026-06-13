#!/usr/bin/env bash
#
# bumkali — full temporary VM setup for Kali Linux / Debian
#
# Run with: sudo ./bumkali-setup.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Keep the machine awake for the whole run.
# Re-exec under systemd-inhibit so the VM cannot suspend, idle-sleep, or be
# powered off (lid/power/suspend keys) while setup is in progress. We do NOT
# block "shutdown" so the intentional reboot at the end still works.
# ---------------------------------------------------------------------------
if [[ -z "${BUMKALI_INHIBITED:-}" ]] && command -v systemd-inhibit >/dev/null 2>&1; then
    export BUMKALI_INHIBITED=1
    exec systemd-inhibit \
        --what=sleep:idle:handle-power-key:handle-suspend-key:handle-hibernate-key:handle-lid-switch \
        --who="bumkali" \
        --why="VM setup in progress" \
        --mode=block \
        "$0" "$@"
fi

# ---------------------------------------------------------------------------
# ASCII banner
# ---------------------------------------------------------------------------
print_banner() {
    cat <<'BANNER'

  ██████╗ ██╗   ██╗███╗   ███╗██╗  ██╗ █████╗ ██╗     ██╗
  ██╔══██╗██║   ██║████╗ ████║██║ ██╔╝██╔══██╗██║     ██║
  ██████╔╝██║   ██║██╔████╔██║█████╔╝ ███████║██║     ██║
  ██╔══██╗██║   ██║██║╚██╔╝██║██╔═██╗ ██╔══██║██║     ██║
  ██████╔╝╚██████╔╝██║ ╚═╝ ██║██║  ██╗██║  ██║███████╗██║
  ╚═════╝  ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝

        Temporary VM Setup  ::  Kali / Debian  ::  bumkali

BANNER
}

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()  { printf '\n\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight: root + sudo invocation
# ---------------------------------------------------------------------------
print_banner

if [[ "$(id -u)" -ne 0 ]]; then
    die "This script must be run as root (use: sudo $0)."
fi

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    die "Could not determine a non-root invoking user. Please launch this script via sudo from a normal user account."
fi

if ! id "$TARGET_USER" >/dev/null 2>&1; then
    die "Detected user '$TARGET_USER' does not exist."
fi

# ---------------------------------------------------------------------------
# Core variables
# ---------------------------------------------------------------------------
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "Home directory for '$TARGET_USER' not found."

TARGET_DESKTOP="$TARGET_HOME/Desktop"
PROJECT_DIR="$TARGET_DESKTOP/project"

export DEBIAN_FRONTEND=noninteractive

# sudo's secure_path on Kali can omit /usr/local/bin — which is exactly where
# npm global binaries (claude, codex) are installed (npm prefix -g = /usr/local).
# Without this, verification can't find them even though they exist.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

ok "Invoking root confirmed."
ok "Target user:    $TARGET_USER"
ok "Target home:    $TARGET_HOME"
ok "Target desktop: $TARGET_DESKTOP"
ok "Project dir:    $PROJECT_DIR"

# Run a command as the target (non-root) user, with a sane interactive PATH.
as_user() {
    sudo -u "$TARGET_USER" \
        HOME="$TARGET_HOME" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "$TARGET_USER")" \
        bash -lc "$1"
}

# Install an npm global package, working around the Debian/Kali npm policy
# that gates package lifecycle scripts ("allow-scripts"). When the launcher
# isn't created because the postinstall was blocked, run it manually.
#   $1 = npm package spec   $2 = expected command name
ensure_npm_global() {
    local pkg="$1" cmd="$2" gprefix
    npm install -g "$pkg"
    hash -r 2>/dev/null || true

    # The npm global bin directory is often NOT on root's sudo PATH (and the
    # Kali "allow-scripts" notice is advisory — the postinstall still runs).
    # Expose the command in /usr/local/bin so both root and the target user
    # can find it.
    gprefix="$(npm prefix -g 2>/dev/null || true)"
    if [[ -n "$gprefix" && -e "$gprefix/bin/$cmd" && "$gprefix/bin/$cmd" != "/usr/local/bin/$cmd" ]]; then
        ln -sf "$gprefix/bin/$cmd" "/usr/local/bin/$cmd"
        ok "Linked /usr/local/bin/$cmd -> $gprefix/bin/$cmd"
    fi
    hash -r 2>/dev/null || true
    command -v "$cmd" >/dev/null 2>&1
}

# ===========================================================================
# Task 1 — Passwordless sudo for the invoking user
# ===========================================================================
log "Task 1: Configuring passwordless sudo for '$TARGET_USER'"

SUDOERS_FILE="/etc/sudoers.d/90-nopasswd-$TARGET_USER"
printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$TARGET_USER" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"
chown root:root "$SUDOERS_FILE"

if visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
    ok "Sudoers drop-in validated: $SUDOERS_FILE"
else
    rm -f "$SUDOERS_FILE"
    die "Sudoers validation failed; removed $SUDOERS_FILE and aborting."
fi

# ===========================================================================
# Task 2 — Disable X11 screen blanking at graphical login
# ===========================================================================
log "Task 2: Disabling screen blanking via autostart entry"

AUTOSTART_DIR="$TARGET_HOME/.config/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/disable-screen-blanking.desktop"

install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 "$TARGET_HOME/.config"
install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 "$AUTOSTART_DIR"

cat > "$AUTOSTART_FILE" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Disable Screen Blanking
Comment=Disable screensaver blanking and DPMS
Exec=sh -c 'sleep 5; xset s noblank; xset s off; xset -dpms'
Terminal=false
X-GNOME-Autostart-enabled=true
DESKTOP

chown "$TARGET_USER:$TARGET_USER" "$AUTOSTART_FILE"
chmod 0644 "$AUTOSTART_FILE"
ok "Autostart entry written: $AUTOSTART_FILE"

# ===========================================================================
# Task 3 — Detect virtualization platform
# ===========================================================================
log "Task 3: Detecting virtualization platform"

VIRT_RAW=""
if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT_RAW="$(systemd-detect-virt --vm 2>/dev/null || true)"
fi

DMI_BLOB=""
for f in /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name /sys/class/dmi/id/board_vendor; do
    [[ -r "$f" ]] && DMI_BLOB+=" $(cat "$f" 2>/dev/null || true)"
done

CLASSIFY_SRC="$(printf '%s %s' "$VIRT_RAW" "$DMI_BLOB" | tr '[:upper:]' '[:lower:]')"

VIRT_TYPE="unknown"
if   [[ "$CLASSIFY_SRC" == *vmware* ]]; then
    VIRT_TYPE="vmware"
elif [[ "$CLASSIFY_SRC" == *virtualbox* || "$CLASSIFY_SRC" == *oracle* ]]; then
    VIRT_TYPE="virtualbox"
elif [[ "$CLASSIFY_SRC" == *qemu*  || "$CLASSIFY_SRC" == *kvm*  || "$CLASSIFY_SRC" == *bochs* \
     || "$CLASSIFY_SRC" == *"red hat"* || "$CLASSIFY_SRC" == *rhev* || "$CLASSIFY_SRC" == *libvirt* ]]; then
    VIRT_TYPE="qemu-kvm"
else
    VIRT_TYPE="unknown"
fi

ok "Detected virtualization type: $VIRT_TYPE"

# ===========================================================================
# Task 3 (cont) — Install x-resize only for QEMU/KVM/virt-manager
# ===========================================================================
if [[ "$VIRT_TYPE" == "qemu-kvm" ]]; then
    log "Installing x-resize (QEMU/KVM detected) as user '$TARGET_USER'"
    as_user '
        set -e
        cd "$HOME"
        wget -O setup-x-resize-xfce-kali.sh https://raw.githubusercontent.com/h0ek/x-resize/refs/heads/main/setup-x-resize-xfce-kali.sh
        chmod +x setup-x-resize-xfce-kali.sh
        ./setup-x-resize-xfce-kali.sh
    ' && ok "x-resize installer completed." || warn "x-resize installer reported an error (verified later)."
else
    echo "x-resize is only being installed for QEMU/KVM/virt-manager"
fi

# ===========================================================================
# Task 4 — System update and upgrade
# ===========================================================================
log "Task 4: Updating and upgrading system packages"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
ok "System update/upgrade complete."

# ===========================================================================
# Task 5 — Install Microsoft VS Code (not code-oss)
# ===========================================================================
log "Task 5: Installing Microsoft Visual Studio Code"

apt-get install -y wget curl gpg apt-transport-https ca-certificates

install -d -m 0755 /etc/apt/keyrings

if [[ ! -s /etc/apt/keyrings/packages.microsoft.gpg ]]; then
    tmp_key="$(mktemp)"
    wget -qO "$tmp_key" https://packages.microsoft.com/keys/microsoft.asc
    gpg --dearmor < "$tmp_key" > /etc/apt/keyrings/packages.microsoft.gpg
    rm -f "$tmp_key"
fi
chmod 0644 /etc/apt/keyrings/packages.microsoft.gpg

echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    > /etc/apt/sources.list.d/vscode.list

apt-get update
apt-get install -y code
ok "VS Code installed from Microsoft repository."

# ===========================================================================
# Task 6 — Install Node.js and npm (if npm missing)
# ===========================================================================
log "Task 6: Ensuring Node.js and npm are installed"
if ! command -v npm >/dev/null 2>&1; then
    apt-get install -y nodejs npm
else
    ok "npm already present; skipping install."
fi
node --version
npm --version
ok "Node.js: $(node --version), npm: $(npm --version)"

# ===========================================================================
# Task 7 — Install Kali wordlists (if missing)
# ===========================================================================
log "Task 7: Ensuring Kali wordlists are installed"
if [[ ! -d /usr/share/wordlists ]]; then
    apt-get install -y wordlists
else
    ok "/usr/share/wordlists already exists; skipping install."
fi
[[ -d /usr/share/wordlists ]] && ok "/usr/share/wordlists present." || warn "/usr/share/wordlists missing (verified later)."

# ===========================================================================
# Task 8 — Install mcp-kali-server (apt)
# ===========================================================================
log "Task 8: Installing mcp-kali-server via apt"

apt-get install -y mcp-kali-server

# The Kali package ships its CLI under a name that is NOT 'mcp-server'
# (e.g. 'kali-server-mcp' / 'kali-mcp-client'). Detect whichever real entry
# point exists and expose it under the name 'mcp-server', which is what
# mcp.json and the Claude/Codex registration reference.
MCP_REAL=""
for cand in mcp-server kali-server-mcp kali-mcp-client mcp-kali-server; do
    if cand_path="$(command -v "$cand" 2>/dev/null)" && [[ -n "$cand_path" ]]; then
        MCP_REAL="$cand_path"
        ok "Found mcp-kali-server entry point: $cand -> $cand_path"
        break
    fi
done

if [[ -z "$MCP_REAL" ]]; then
    die "mcp-kali-server installed but no known entry point found (looked for: mcp-server, kali-server-mcp, kali-mcp-client, mcp-kali-server). Aborting before reboot."
fi

# Provide a stable, system-wide 'mcp-server' command if the real binary
# is named something else. /usr/local/bin is on PATH for root and the user.
if [[ "$(basename "$MCP_REAL")" != "mcp-server" ]]; then
    ln -sf "$MCP_REAL" /usr/local/bin/mcp-server
    ok "Linked /usr/local/bin/mcp-server -> $MCP_REAL"
fi

if command -v mcp-server >/dev/null 2>&1; then
    ok "mcp-server command available: $(command -v mcp-server)"
else
    die "Could not expose 'mcp-server' on PATH. Aborting before reboot."
fi

# ===========================================================================
# Task 9 — Install Claude Code CLI
# ===========================================================================
log "Task 9: Installing Claude Code CLI"
ensure_npm_global "@anthropic-ai/claude-code" "claude" || true

# Fallback: official native installer (per target user), then expose it
# system-wide so both root and the target user can run 'claude'.
if ! command -v claude >/dev/null 2>&1; then
    warn "Falling back to the official Claude Code installer (as $TARGET_USER)."
    as_user 'curl -fsSL https://claude.ai/install.sh | bash' || true
    # The native installer drops 'claude' in the user's ~/.local/bin. Locate it
    # via the user's login shell, then expose it system-wide.
    claude_path="$(as_user 'command -v claude' 2>/dev/null || true)"
    if [[ -z "$claude_path" && -e "$TARGET_HOME/.local/bin/claude" ]]; then
        claude_path="$TARGET_HOME/.local/bin/claude"
    fi
    if [[ -n "$claude_path" ]]; then
        ln -sf "$claude_path" /usr/local/bin/claude
        ok "Linked /usr/local/bin/claude -> $claude_path"
    fi
    hash -r 2>/dev/null || true
fi

if command -v claude >/dev/null 2>&1; then
    ok "Claude Code: $(claude --version 2>/dev/null || echo installed)"
else
    warn "Claude Code CLI not detected after install attempts (reported in final verification)."
fi

# ===========================================================================
# Task 10 — Install OpenAI Codex CLI
# ===========================================================================
log "Task 10: Installing OpenAI Codex CLI"
ensure_npm_global "@openai/codex" "codex" || true

if command -v codex >/dev/null 2>&1; then
    ok "Codex: $(codex --version 2>/dev/null || echo installed)"
else
    warn "Codex CLI not detected after install attempts (reported in final verification)."
fi

# ===========================================================================
# Task 11 — Create project folder + .vscode/mcp.json
# ===========================================================================
log "Task 11: Creating project folder and mcp.json"

install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 "$TARGET_DESKTOP"
install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 "$PROJECT_DIR"
install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 "$PROJECT_DIR/.vscode"

cat > "$PROJECT_DIR/.vscode/mcp.json" <<'JSON'
{
  "servers": {
    "kali": {
      "command": "mcp-server",
      "args": ["--server", "http://127.0.0.1:5000"]
    }
  }
}
JSON

chown -R "$TARGET_USER:$TARGET_USER" "$PROJECT_DIR"
ok "Project created at $PROJECT_DIR"

# ===========================================================================
# Task 12 — Register the kali MCP server with Claude Code (as target user)
# ===========================================================================
log "Task 12: Registering 'kali' MCP server with Claude Code (user scope)"

# Use USER scope so the server is available from every directory. The default
# 'local' scope binds the server to the directory it was added from, so it
# would not appear when running 'claude mcp list' from elsewhere (e.g. $HOME).
# Remove any stale entry first to keep this idempotent.
as_user 'claude mcp remove kali --scope user >/dev/null 2>&1 || true'
as_user 'claude mcp remove kali >/dev/null 2>&1 || true'
if as_user 'claude mcp add kali --scope user -- mcp-server --server http://127.0.0.1:5000'; then
    ok "'kali' MCP server registered at user scope."
else
    warn "claude mcp add reported an error (verified later)."
fi

# ===========================================================================
# Task 13 — Final verification
# ===========================================================================
log "Task 13: Running final verification checks"

FAILED=()
check() {
    # check "<description>" <test-command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        ok "PASS: $desc"
    else
        warn "FAIL: $desc"
        FAILED+=("$desc")
    fi
}

# Running as root
check "running as root" test "$(id -u)" -eq 0

# Target user / home exist
check "TARGET_USER '$TARGET_USER' exists" id "$TARGET_USER"
check "TARGET_HOME '$TARGET_HOME' exists" test -d "$TARGET_HOME"

# Passwordless sudo works
check "passwordless sudo works for '$TARGET_USER'" sudo -u "$TARGET_USER" sudo -n true

# Autostart file
check "autostart .desktop exists" test -f "$AUTOSTART_FILE"

# Virtualization detected and printed
check "virtualization type detected" test -n "$VIRT_TYPE"
ok "Virtualization type: $VIRT_TYPE"

# x-resize checks only for qemu-kvm
if [[ "$VIRT_TYPE" == "qemu-kvm" ]]; then
    if [[ -x "$TARGET_HOME/.local/bin/x-resize-xfce" ]] \
       || as_user 'command -v x-resize-xfce >/dev/null 2>&1' \
       || as_user 'command -v x-resize >/dev/null 2>&1'; then
        ok "PASS: x-resize executable present"
    else
        warn "FAIL: x-resize executable not found"
        FAILED+=("x-resize executable present")
    fi

    XRES_SERVICE="$TARGET_HOME/.config/systemd/user/x-resize-xfce.service"
    if [[ -f "$XRES_SERVICE" ]]; then
        ok "PASS: x-resize-xfce.service unit exists"
        if as_user 'systemctl --user is-enabled x-resize-xfce.service >/dev/null 2>&1'; then
            ok "PASS: x-resize-xfce.service is enabled"
        else
            warn "x-resize-xfce.service exists but is not enabled (non-fatal)."
        fi
    else
        warn "x-resize-xfce.service unit not created by installer (non-fatal)."
    fi
else
    ok "Skipping x-resize verification (virt type: $VIRT_TYPE)."
fi

# Toolchain commands
check "'code' command exists" command -v code
check "'npm' command exists"  command -v npm
check "'node' command exists" command -v node
check "'mcp-server' command exists (target user)" sudo -u "$TARGET_USER" bash -lc 'command -v mcp-server'
check "'claude' command exists" command -v claude
check "'codex' command exists"  command -v codex

# VS Code is Microsoft's, not code-oss
# The Microsoft package is literally named 'code' (Kali's open-source build is
# the separate 'code-oss' package), and its maintainer is "Microsoft
# Corporation". apt-cache policy output format varies between hosts, so accept
# any of several conclusive signals that this is Microsoft's build.
code_policy="$(apt-cache policy code 2>/dev/null || true)"
code_maint="$(dpkg-query -W -f='${Maintainer}' code 2>/dev/null || true)"
if printf '%s\n%s\n' "$code_policy" "$code_maint" | grep -qiE 'microsoft' \
   || { [[ -f /etc/apt/sources.list.d/vscode.list ]] \
        && grep -qi 'packages\.microsoft\.com' /etc/apt/sources.list.d/vscode.list \
        && dpkg-query -s code >/dev/null 2>&1; }; then
    ok "PASS: 'code' is Microsoft VS Code (not code-oss) [maintainer: ${code_maint:-unknown}]"
else
    warn "FAIL: 'code' is not sourced from Microsoft's repository"
    FAILED+=("code from Microsoft repository (not code-oss)")
fi

# Wordlists
check "/usr/share/wordlists exists" test -d /usr/share/wordlists

# Project mcp.json exists and is valid JSON
MCP_JSON="$PROJECT_DIR/.vscode/mcp.json"
check "mcp.json exists" test -f "$MCP_JSON"
if command -v python3 >/dev/null 2>&1; then
    check "mcp.json is valid JSON" python3 -c "import json,sys; json.load(open('$MCP_JSON'))"
elif command -v node >/dev/null 2>&1; then
    check "mcp.json is valid JSON" node -e "JSON.parse(require('fs').readFileSync('$MCP_JSON','utf8'))"
else
    warn "No JSON validator available; skipping mcp.json validation."
fi

# claude mcp list contains kali (as target user)
check "'claude mcp list' contains 'kali'" sudo -u "$TARGET_USER" bash -lc 'cd "$HOME" 2>/dev/null; claude mcp list 2>/dev/null | grep -q kali'

# ===========================================================================
# Task 14 — Reboot only if everything passed
# ===========================================================================
if [[ ${#FAILED[@]} -ne 0 ]]; then
    printf '\n\033[1;31m========================= FAILURE REPORT =========================\033[0m\n'
    printf 'The following %d check(s) failed:\n\n' "${#FAILED[@]}"
    for item in "${FAILED[@]}"; do
        printf '  \033[1;31m✗\033[0m %s\n' "$item"
    done
    printf '\n\033[1;31mNOT rebooting. Resolve the issues above and re-run this script.\033[0m\n\n'
    exit 1
fi

printf '\n\033[1;32m===================== ALL CHECKS PASSED =====================\033[0m\n'
echo "All checks passed. Rebooting in 10 seconds..."
sleep 10
reboot
