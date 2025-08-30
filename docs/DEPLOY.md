# CLMS Deployment Guide

## Overview

- Full-stack app with a Laravel API (PHP 8.3, Postgres, Redis) and a Next.js frontend.
- Docker Compose orchestrates all services for local dev and deployment.

## Production

- Live app: <https://clms.attara.dev>

---

## Quick Start (Docker)

### Prereqs

- Docker Desktop 4.24+

### Setup

1. Create cookie secret:

   ```bash
   mkdir -p .secrets && openssl rand -base64 48 > .secrets/SECRET_COOKIE_PASSWORD
   ````

2. Backend env:

   ```bash
   cp back-end/.env.example back-end/.env
   docker compose up -d --build
   ```

3. Generate app key + migrate/seed:

   ```bash
   docker compose exec api php artisan key:generate
   docker compose exec api php artisan migrate --seed
   ```

4. Open:

   - Web: [http://localhost:3000](http://localhost:3000)
   - Proxy: [http://localhost:8000](http://localhost:8000)

### Seeded Login

- Username: `admin`
- Password: `admin`

---

## Project Structure

- `back-end/`: Laravel app (API) and Nginx reverse proxy.
- `front-end/`: Next.js app.
- `compose.yml`: Local/dev stack.
- `.secrets/SECRET_COOKIE_PASSWORD`: 32+ char secret for session encryption.

---

## Service Names

- **api** (Laravel PHP-FPM): `clms-api`
- **proxy** (Nginx → api): `clms-proxy`
- **web** (Next.js): `clms-web`

---

## Frontend → API Bridge

- Calls to `/api/bridge/...` proxied to `${BACKEND_API_HOST}` (`http://proxy:80` in Compose).
- Implemented in `front-end/pages/api/bridge/[...path].js`.

---

## Common Commands

- Up: `docker compose up -d --build`
- Logs: `docker compose logs -f web proxy api`
- Backend tests: `docker compose exec api php artisan test`
- Reset DB: `docker compose down -v && docker compose up -d --build`

---

## Environments

- Backend: `back-end/.env` (DB defaults from Compose).
- Frontend: `front-end/.env` overrides like `COOKIE_SECURE`.
- Secrets: `.secrets/SECRET_COOKIE_PASSWORD`.

---

## Networks

- Local: `clms_dev`
- Production: `clms_prod`

---

## Production Compose Override

- Uses prebuilt images (`compose.prod.yml`).
- Example:

  ```bash
  docker compose -f compose.yml -f compose.prod.yml up -d
  ```

- Env vars:

  - `DOCKERHUB_NAMESPACE`
  - `TAG` (optional; default `latest`)
  - `SECRET_COOKIE_PASSWORD`

---

## Deployment (GitHub Actions)

Workflow: `.github/workflows/ci-cd.yml`

- **Images**:
  `${DOCKERHUB_NAMESPACE}/clms-web`, `${DOCKERHUB_NAMESPACE}/clms-api`, `${DOCKERHUB_NAMESPACE}/clms-proxy`
- **Tags**: `latest`, `sha-<commit>`, Git tags.
- **Secrets**:

  - `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `DOCKERHUB_NAMESPACE`
  - `SSH_HOST`, `SSH_USER`, `SSH_KEY`, `SSH_PORT` (opt), `REMOTE_PATH`
  - `SECRET_COOKIE_PASSWORD`, `DOMAIN_NAME`, `ACME_EMAIL`

### Deploy does

- Writes `${REMOTE_PATH}/.env`
- Ensures `${REMOTE_PATH}/letsencrypt/acme.json` (mode 600)
- Runs `docker compose -f compose.prod.yml up -d --remove-orphans`
- Runs migrations & seeding:

  ```bash
  docker compose -f compose.prod.yml exec -T api php artisan migrate --force
  docker compose -f compose.prod.yml exec -T api php artisan db:seed --force
  ```

---

## Server Init

Bootstrap new server:

```bash
sudo bash scripts/init-server.sh /opt/clms
```

- Installs Docker, sets up `.env` with `APP_KEY`, prepares `letsencrypt/acme.json`.
- After, configure GitHub secrets and deploy from `main`.

---

## Provision EC2 with Terraform

Directory: `infra/terraform`

### Requires

- Terraform >= 1.3
- AWS creds

### Creates

- Ubuntu 24.04 EC2
- Security group (22,80,443)
- Elastic IP (optional)

### Usage

```bash
cd infra/terraform
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

Example `terraform.tfvars`:

```hcl
aws_region      = "us-east-1"
ssh_key_name    = "your-keypair"
allowed_ssh_cidr = "x.x.x.x/32"
attach_eip      = true
remote_path     = "/opt/clms"
domain_name     = "app.example.com"
```

Outputs: `public_ip`, `ssh_user`, `ssh_command`, `remote_path`, `https_url`.

Set CI secrets accordingly.

---

## API Highlights

- Users CRUD: `/api/admin/users`
- Auth: `/api/login`, `/api/logout`

---

## TLS (Production)

- Traefik in `compose.prod.yml` handles TLS with Let’s Encrypt.
- ACME storage: `${REMOTE_PATH}/letsencrypt/acme.json`

### Requirements

- DNS A record → server IP
- Ports 80/443 open
- Disable Cloudflare proxy or switch to DNS challenge

### Debug

```bash
docker compose -f compose.prod.yml logs -f traefik | grep -i acme
curl -I http://<DOMAIN_NAME>
```

---

## Database & Seeding

Deployment auto-runs migrations + seeds admin (`admin`/`admin`).
Manual rerun:

```bash
cd ${REMOTE_PATH}
sudo docker compose -f compose.prod.yml exec -T api php artisan migrate --force
sudo docker compose -f compose.prod.yml exec -T api php artisan db:seed --force
```
