#!/usr/bin/env bash

# CLMS server bootstrap for Docker-based deployment
# - Installs Docker Engine + compose-plugin (on Ubuntu/Debian server)
# - Creates deployment directory structure
# - Generates Laravel .env with production defaults (including APP_KEY)
# - Local mode: run ON the server with sudo
# - Remote mode: run FROM your machine; this script SSHes into the server and runs itself with sudo
# - Optional: consumes Terraform outputs.json to prefill REMOTE_PATH, APP_URL and host
#
# Local usage (run on server):
#   sudo bash scripts/init-server.sh [-o outputs.json] [REMOTE_PATH]
#
# Remote usage (run on your Mac/Linux):
#   bash scripts/init-server.sh --ssh-host <ip-or-host> --ssh-user ubuntu \
#        --ssh-key ~/.ssh/id_ed25519 [-o infra/terraform/outputs.json]

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
  bash scripts/init-server.sh --ssh-host <ip-or-host> --ssh-user ubuntu \
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
        # Positional REMOTE_PATH if not set yet
        if [ -z "$REMOTE_PATH" ]; then REMOTE_PATH="$1"; shift; else echo "Unknown arg: $1" >&2; usage; exit 1; fi;;
    esac
  done
}

json_get() {
  # json_get <key> <file>
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
  curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker

  # Add invoking user to docker group for rootless usage next sessions
  if id -nG "${SUDO_USER:-$USER}" | grep -qvE '\bdocker\b'; then
    usermod -aG docker "${SUDO_USER:-$USER}" || true
    warn "Added ${SUDO_USER:-$USER} to docker group. Log out/in to take effect."
  fi

  info "Docker version: $(docker --version)"
  info "Compose version: $(docker compose version)"
}

make_layout() {
  info "Preparing deployment layout at $REMOTE_PATH ..."
  mkdir -p "$REMOTE_PATH/back-end" "$REMOTE_PATH/letsencrypt"
  chmod 750 "$REMOTE_PATH" || true
}

ensure_backend_env() {
  local env_file="$REMOTE_PATH/back-end/.env"
  if [ -f "$env_file" ]; then
    info "Existing $env_file found. Skipping generation."
    return
  fi

  info "Generating Laravel .env at $env_file"
  # Generate a base64 32-byte key compatible with Laravel
  local app_key="base64:$(openssl rand -base64 32)"

  # derive APP_URL and domains (from flags or outputs.json)
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

  # Patch SANCTUM/SESSION domains if host provided
  if [ -n "$host_name" ]; then
    sed -i "s#^SANCTUM_STATEFUL_DOMAINS=.*#SANCTUM_STATEFUL_DOMAINS=${host_name}#" "$env_file" || true
    sed -i "s#^SESSION_DOMAIN=.*#SESSION_DOMAIN=${host_name}#" "$env_file" || true
  fi

  chmod 640 "$env_file" || true
}

main() {
  parse_args "$@"

  # Remote mode: SSH into server and run this script there (no local sudo required)
  if [ -n "$SSH_HOST" ]; then
    command -v ssh >/dev/null 2>&1 || { err "ssh not found"; exit 1; }
    # Prepare outputs on remote if provided
    remote_outputs=""
    if [ -n "$OUTPUTS_JSON" ] && [ -f "$OUTPUTS_JSON" ]; then
      command -v scp >/dev/null 2>&1 || { err "scp not found"; exit 1; }
      remote_outputs="/tmp/clms-outputs.json"
      info "Copying outputs to $SSH_HOST:$remote_outputs"
      scp -P "$SSH_PORT" ${SSH_KEY:+-i "$SSH_KEY"} "$OUTPUTS_JSON" "$SSH_USER@$SSH_HOST:$remote_outputs"
    fi

    # Build remote flags (do not include any --ssh-* flags)
    remote_flags=""
    [ -n "$remote_outputs" ] && remote_flags+=" -o $remote_outputs"
    [ -n "$REMOTE_PATH" ] && remote_flags+=" --remote-path $REMOTE_PATH"
    [ -n "$APP_URL" ] && remote_flags+=" --app-url $APP_URL"
    [ -n "$HOST_NAME" ] && remote_flags+=" --host $HOST_NAME"

    info "Running init on $SSH_HOST as $SSH_USER ..."
    # Pipe this script to the remote and execute with sudo
    ssh -o StrictHostKeyChecking=accept-new -p "$SSH_PORT" ${SSH_KEY:+-i "$SSH_KEY"} "$SSH_USER@$SSH_HOST" \
      "sudo bash -s -- $remote_flags" < "$0"
    info "Remote init completed"
    exit 0
  fi

  # Local mode (running on the target host)
  require_root
  detect_apt

  # Derive REMOTE_PATH from outputs if not set
  if [ -z "$REMOTE_PATH" ] && [ -n "$OUTPUTS_JSON" ] && [ -f "$OUTPUTS_JSON" ]; then
    REMOTE_PATH="$(json_get remote_path "$OUTPUTS_JSON")"
  fi
  if [ -z "$REMOTE_PATH" ]; then REMOTE_PATH="/opt/clms"; fi

  install_docker
  make_layout
  ensure_backend_env

  info "Done. Next steps:"
  echo "  - Add GitHub repo secrets for CI/CD (see README)."
  echo "  - On first deploy, the workflow will create compose.yml and pull images."
  echo "  - If you change DB credentials above, also update your Compose/Secrets accordingly."
}

main "$@"
