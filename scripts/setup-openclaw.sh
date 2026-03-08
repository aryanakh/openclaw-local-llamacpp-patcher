#!/usr/bin/env bash
# setup-openclaw.sh — Install llama-proxy + systemd services
# 
# Run as root:  sudo bash scripts/setup-openclaw.sh
# Requires:    llama.cpp already installed (llama-qwen.service already running)
set -euo pipefail

SCRIPT_DIR=”$(cd “$(dirname “${BASH_SOURCE[0]}”)” && pwd)”
REPO_DIR=”$(dirname “${SCRIPT_DIR}”)”
INSTALL_DIR=”/home/arya/llama.cpp”
PROXY_SRC=”${REPO_DIR}/proxy/llama-proxy.py”
SYSTEMD_DIR=”/etc/systemd/system”

# Detect the user who invoked sudo (so we run the proxy as that user, not root)

PROXY_USER=”${SUDO_USER:-$(logname 2>/dev/null || echo nobody)}”
PYTHON_BIN=”$(su - “${PROXY_USER}” -c ‘which python3’ 2>/dev/null || which python3)”

RED=’\033[0;31m’; GREEN=’\033[0;32m’; YELLOW=’\033[1;33m’; NC=’\033[0m’
info() { echo -e “${GREEN}[setup]${NC} $*”; }
warn() { echo -e “${YELLOW}[setup]${NC} $*”; }
die()  { echo -e “${RED}[setup] ERROR:${NC} $*” >&2; exit 1; }

# ── 0. Checks ─────────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die “Run this script as root (sudo bash $0)”
[[ -f “${PROXY_SRC}” ]] || die “Proxy script not found at ${PROXY_SRC}”
[[ -f “${INSTALL_DIR}/build/bin/llama-server” ]] || die “llama-server not found at ${INSTALL_DIR}/build/bin/llama-server”

# ── 1. Copy proxy script ──────────────────────────────────────────────────────

info “Installing proxy to ${INSTALL_DIR}/llama-proxy.py…”
cp “${PROXY_SRC}” “${INSTALL_DIR}/llama-proxy.py”
chmod 755 “${INSTALL_DIR}/llama-proxy.py”

# ── 2. Patch BACKEND_URL in the proxy script to match llama-qwen port (8080) ──

info “Patching proxy backend port to 8080…”
sed -i ‘s|BACKEND_URL = “http://127.0.0.1:8001”|BACKEND_URL = “http://127.0.0.1:8080”|’   
“${INSTALL_DIR}/llama-proxy.py”

# ── 3. Write llama-proxy systemd unit ────────────────────────────────────────

info “Writing systemd unit: llama-proxy.service (port 8000 → 8080)…”
cat > “${SYSTEMD_DIR}/llama-proxy.service” << EOF
[Unit]
Description=llama-proxy (role rewrite + thinking control, port 8000->8080)
After=network.target llama-qwen.service
Requires=llama-qwen.service

[Service]
Type=simple
User=${PROXY_USER}
ExecStart=${PYTHON_BIN} ${INSTALL_DIR}/llama-proxy.py
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/llama-proxy.log
StandardError=append:/var/log/llama-proxy.log

[Install]
WantedBy=multi-user.target
EOF

# ── 4. Enable + start ─────────────────────────────────────────────────────────

info “Enabling and starting llama-proxy…”
systemctl daemon-reload
systemctl enable llama-proxy

# Make sure llama-qwen is already running

info “Checking llama-qwen is running…”
systemctl is-active –quiet llama-qwen || die “llama-qwen.service is not running — start it first with: sudo systemctl start llama-qwen”

systemctl start llama-proxy
sleep 2

# ── 5. Verify ─────────────────────────────────────────────────────────────────

info “Verifying proxy health check…”
HEALTH=$(curl -sf http://127.0.0.1:8000/health 2>/dev/null || echo “FAILED”)
if echo “${HEALTH}” | grep -q ok; then
echo “”
echo -e “${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}”
echo -e “${GREEN} Setup complete!${NC}”
echo -e “${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}”
echo “”
echo “  llama-qwen    →  http://127.0.0.1:8080  (internal)”
echo “  llama-proxy   →  http://127.0.0.1:8000  (openclaw connects here)”
echo “”
echo “Next step: add the llamacpp provider to ~/.openclaw/openclaw.json”
echo “  See: openclaw/provider-snippet.json”
echo “”
else
die “Proxy health check failed. Check: journalctl -u llama-proxy -u llama-qwen”
fi
