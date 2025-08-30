#!/usr/bin/env bash

# CLMS server bootstrap for Docker-based deployment
# - Installs Docker Engine + compose-plugin (on Ubuntu/Debian server)
# - Creates deployment directory structure
# - Generates Laravel .env with production defaults (including APP_KEY)
# - Sets up Traefik fallback TLS (self-signed) so HTTPS handshakes succeed
# - Installs a systemd unit so the stack starts on boot (when compose.prod.yml is present)
# - Local mode: run ON the server with sudo
# - Remote mode: run FROM your machine; this script SSHes into the server and runs itself with sudo
# - Optional: consumes Terraform outputs.json to prefill REMOTE_PATH, APP_URL and host

set -euo pipefail

# Inputs (can be set by flags)
OUTPUTS_JSON=""
REMOTE_PATH=""
APP_URL=""
HOST_NAME=""

# SSH (remote mode)
SSH_HOST=""
SSH_USER="ubuntu"
SSH_KEY=""
SSH_PORT="22"

usage() {
  cat <<USAGE
CLMS init server

Local mode (run on the target server):
  sudo bash scripts/init-server.sh [-o outputs.json] [REMOTE_PATH]

Remote mode (run from your machine):
  bash scripts/init-server.sh --ssh-host <ip-or-host> --ssh-user ubuntu \\
       --ssh-key ~/.ssh/id_ed25519 [-o infra/terraform/outputs.json]

Options:
  -o, --outputs <file>   Path to Terraform outputs.json (to populate APP_URL/host/remote_path)
  --remote-path <path>   Deployment directory (default /opt/clms)
  --app-url <url>        Override APP_URL in back-end/.env
  --host <hostname>      Override SANCTUM/SESSION domains
  --ssh-host <host>      SSH target host/IP (enables remote mode)
  --ssh-user <user>      SSH username (default: ubuntu)
  --ssh-key  <path>      SSH private key path
  --ssh-port <port>      SSH port (default: 22)
  -h, --help             Show this help
USAGE
}

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR ]\033[0m $*"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Please run as root (use sudo)."
    exit 1
  fi
}

detect_apt() {
  if ! command -v apt-get >/dev/null 2>&1; then
    err "This script targets Debian/Ubuntu hosts (apt-get not found)."
    exit 1
  fi
}

parse_args() {
  while (( "$#" )); do
    case "$1" in
      -o|--outputs) OUTPUTS_JSON="$2"; shift 2;;
      --remote-path) REMOTE_PATH="$2"; shift 2;;
      --app-url) APP_URL="$2"; shift 2;;
      --host) HOST_NAME="$2"; shift 2;;
      --ssh-host) SSH_HOST="$2"; shift 2;;
      --ssh-user) SSH_USER="$2"; shift 2;;
      --ssh-key) SSH_KEY="$2"; shift 2;;
      --ssh-port) SSH_PORT="$2"; shift 2;;
      -h|--help) usage; exit 0;;
      *)
        if [ -z "$REMOTE_PATH" ]; then REMOTE_PATH="$1"; shift; else echo "Unknown arg: $1" >&2; usage; exit 1; fi;;
    esac
  done
}

json_get() {
  local key="$1" file="$2"
  if [ -z "$file" ] || [ ! -f "$file" ]; then return 1; fi
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" '.[$k].value // empty' "$file" 2>/dev/null || true
  else
    python3 - <<PY 2>/dev/null || true
import json,sys
try:
  d=json.load(open('$file'))
  v=d.get('$key',{}).get('value','')
  print(v if v is not None else '')
except Exception:
  pass
PY
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    info "Docker and compose already installed. Skipping."
    return
  fi

  info "Installing Docker Engine + compose plugin..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release openssl jq

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg" | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker

  if id -nG "${SUDO_USER:-$USER}" | grep -qvE '\bdocker\b'; then
    usermod -aG docker "${SUDO_USER:-$USER}" || true
    warn "Added ${SUDO_USER:-$USER} to docker group. Log out/in to take effect."
  fi

  info "Docker version: $(docker --version)"
  info "Compose version: $(docker compose version)"
}

make_layout() {
  info "Preparing deployment layout at $REMOTE_PATH ..."
  mkdir -p "$REMOTE_PATH/back-end" \
           "$REMOTE_PATH/letsencrypt" \
           "$REMOTE_PATH/dynamic"
  chmod 750 "$REMOTE_PATH" || true

  # ACME storage for Traefik (strict perms)
  touch "$REMOTE_PATH/letsencrypt/acme.json"
  chmod 600 "$REMOTE_PATH/letsencrypt/acme.json" || true
}

ensure_fallback_tls() {
  local crt="$REMOTE_PATH/dynamic/default.crt"
  local key="$REMOTE_PATH/dynamic/default.key"
  local tls="$REMOTE_PATH/dynamic/tls.yml"

  if [ ! -f "$crt" ] || [ ! -f "$key" ]; then
    info "Generating fallback self-signed TLS certificate ..."
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -subj "/CN=default.local" \
      -keyout "$key" \
      -out   "$crt"
    chmod 600 "$key" || true
    chmod 644 "$crt" || true
  fi

  if [ ! -f "$tls" ]; then
    info "Writing /dynamic/tls.yml"
    cat > "$tls" <<'YAML'
tls:
  certificates:
    - certFile: /dynamic/default.crt
      keyFile: /dynamic/default.key
YAML
  fi
}

ensure_backend_env() {
  local env_file="$REMOTE_PATH/back-end/.env"
  if [ -f "$env_file" ]; then
    info "Existing $env_file found. Skipping generation."
    return
  fi

  info "Generating Laravel .env at $env_file"
  local app_key="base64:$(openssl rand -base64 32)"

  local app_url="$APP_URL" host_name="$HOST_NAME"
  if [ -z "$app_url" ] && [ -n "$OUTPUTS_JSON" ] && [ -f "$OUTPUTS_JSON" ]; then
    app_url="$(json_get https_url "$OUTPUTS_JSON")"
    host_name="$(json_get host "$OUTPUTS_JSON")"
  fi
  if [ -z "$app_url" ]; then app_url="http://localhost:8000"; fi

  cat > "$env_file" <<EOF
APP_NAME=CLMS
APP_ENV=production
APP_KEY=$app_key
APP_DEBUG=false
APP_URL=$app_url

LOG_CHANNEL=stack
LOG_LEVEL=info

DB_CONNECTION=pgsql
DB_HOST=db
DB_PORT=5432
DB_DATABASE=clms
DB_USERNAME=clms
DB_PASSWORD=clms

BROADCAST_DRIVER=log
CACHE_DRIVER=file
FILESYSTEM_DISK=local
QUEUE_CONNECTION=database
SESSION_DRIVER=file
SESSION_LIFETIME=120

REDIS_HOST=redis
REDIS_PASSWORD=null
REDIS_PORT=6379

SANCTUM_STATEFUL_DOMAINS=
SESSION_DOMAIN=
EOF

  if [ -n "$host_name" ]; then
    sed -i "s#^SANCTUM_STATEFUL_DOMAINS=.*#SANCTUM_STATEFUL_DOMAINS=${host_name}#" "$env_file" || true
    sed -i "s#^SESSION_DOMAIN=.*#SESSION_DOMAIN=${host_name}#" "$env_file" || true
  fi
  chmod 640 "$env_file" || true
}

install_systemd_unit() {
  info "Installing systemd unit to start the stack on boot"

  # --------- helper script (idempotent write) ----------
  local tmp_stack
  tmp_stack="$(mktemp)"
  cat > "$tmp_stack" <<SH
#!/usr/bin/env bash
set -euo pipefail
CMD="\${1:-up}"
COMPOSE="$REMOTE_PATH/compose.prod.yml"
cd "$REMOTE_PATH" || exit 0
# Load .env if present so compose sees DOMAIN_NAME/etc
[ -f .env ] && set -a && . ./.env && set +a || true
if [ ! -f "\$COMPOSE" ]; then
  echo "[clms] compose.prod.yml not found, skipping (\${CMD})"
  exit 0
fi
case "\$CMD" in
  up)    exec docker compose -f "\$COMPOSE" up -d ;;
  down)  exec docker compose -f "\$COMPOSE" down   ;;
  *)     echo "Usage: clms-stack.sh [up|down]"; exit 2 ;;
esac
SH

  if [ ! -f /usr/local/bin/clms-stack.sh ] || ! cmp -s "$tmp_stack" /usr/local/bin/clms-stack.sh; then
    install -m 0755 "$tmp_stack" /usr/local/bin/clms-stack.sh
  fi
  rm -f "$tmp_stack"

  # --------- systemd unit (idempotent write) ----------
  local tmp_unit
  tmp_unit="$(mktemp)"
  cat > "$tmp_unit" <<UNIT
[Unit]
Description=CLMS stack (Docker Compose)
Requires=docker.service
Wants=network-online.target
After=docker.service network-online.target

[Service]
Type=oneshot
WorkingDirectory=$REMOTE_PATH
ExecStart=/usr/local/bin/clms-stack.sh up
ExecReload=/usr/local/bin/clms-stack.sh up
ExecStop=/usr/local/bin/clms-stack.sh down
RemainAfterExit=true
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT

  local unit_path="/etc/systemd/system/clms.service"
  local changed=0
  if [ ! -f "$unit_path" ] || ! cmp -s "$tmp_unit" "$unit_path"; then
    install -m 0644 "$tmp_unit" "$unit_path"
    systemctl daemon-reload
    changed=1
  fi
  rm -f "$tmp_unit"

  if ! systemctl is-enabled --quiet clms.service; then
    systemctl enable clms.service || true
    changed=1
  fi

  if systemctl is-active --quiet clms.service; then
    [ "$changed" -eq 1 ] && (systemctl reload clms.service || systemctl restart clms.service || true)
  else
    systemctl start clms.service || true
  fi
}

maybe_open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
      info "UFW is active; allowing 80/tcp and 443/tcp"
      ufw allow 80/tcp || true
      ufw allow 443/tcp || true
    fi
  fi
}

main() {
  parse_args "$@"

  # Remote mode
  if [ -n "$SSH_HOST" ]; then
    command -v ssh >/dev/null 2>&1 || { err "ssh not found"; exit 1; }
    local remote_outputs=""
    if [ -n "$OUTPUTS_JSON" ] && [ -f "$OUTPUTS_JSON" ]; then
      command -v scp >/dev/null 2>&1 || { err "scp not found"; exit 1; }
      remote_outputs="/tmp/clms-outputs.json"
      info "Copying outputs to $SSH_HOST:$remote_outputs"
      scp -P "$SSH_PORT" ${SSH_KEY:+-i "$SSH_KEY"} "$OUTPUTS_JSON" "$SSH_USER@$SSH_HOST:$remote_outputs"
    fi

    local remote_flags=""
    [ -n "$remote_outputs" ] && remote_flags+=" -o $remote_outputs"
    [ -n "$REMOTE_PATH" ] && remote_flags+=" --remote-path $REMOTE_PATH"
    [ -n "$APP_URL" ] && remote_flags+=" --app-url $APP_URL"
    [ -n "$HOST_NAME" ] && remote_flags+=" --host $HOST_NAME"

    info "Running init on $SSH_HOST as $SSH_USER ..."
    ssh -o StrictHostKeyChecking=accept-new -p "$SSH_PORT" ${SSH_KEY:+-i "$SSH_KEY"} "$SSH_USER@$SSH_HOST" \
      "sudo bash -s -- $remote_flags" < "$0"
    info "Remote init completed"
    exit 0
  fi

  # Local mode
  require_root
  detect_apt

  if [ -z "$REMOTE_PATH" ] && [ -n "$OUTPUTS_JSON" ] && [ -f "$OUTPUTS_JSON" ]; then
    REMOTE_PATH="$(json_get remote_path "$OUTPUTS_JSON")"
  fi
  if [ -z "$REMOTE_PATH" ]; then REMOTE_PATH="/opt/clms"; fi

  install_docker
  make_layout
  ensure_fallback_tls     # so HTTPS works for unknown hosts (Traefik will 404)
  ensure_backend_env
  install_systemd_unit
  maybe_open_firewall

  info "Done. Next steps:"
  echo "  - Put your compose.prod.yml in $REMOTE_PATH (CI does this automatically)."
  echo "  - Ensure DOMAIN_NAME and ACME_EMAIL are set in $REMOTE_PATH/.env (CI writes them)."
  echo "  - Systemd unit is enabled: 'systemctl status clms.service'"
  echo "  - After compose is present, start now or on reboot:"
  echo "      sudo systemctl restart clms.service"
}

main "$@"
