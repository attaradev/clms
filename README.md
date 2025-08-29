# CLMS

Overview

- Full‑stack app with a Laravel API (PHP 8.3, Postgres, Redis) and a Next.js frontend.
- Docker Compose orchestrates all services for local dev and deployment.

Production

- Live app: https://clms.attara.dev

Quick Start (Docker)

- Prereqs: Docker Desktop 4.24+.
- Create cookie secret: `mkdir -p .secrets && openssl rand -base64 48 > .secrets/SECRET_COOKIE_PASSWORD`.
- Backend env: `cp back-end/.env.example back-end/.env && docker compose up -d --build`.
- Generate app key + migrate and seed:
  - `docker compose exec api php artisan key:generate`
  - `docker compose exec api php artisan migrate --seed`
- Open web: <http://localhost:3000>
- Proxy (Nginx): <http://localhost:8000>

Login (seeded)

- Username: `admin`
- Password: `admin`

Project Structure

- `back-end/`: Laravel app (API) and Nginx reverse proxy.
- `front-end/`: Next.js app. Uses an API bridge (`/api/bridge/*`) to talk to backend.
- `compose.yml`: Local/dev stack (proxy, api, web, db, redis).
- `.secrets/SECRET_COOKIE_PASSWORD`: 32+ char secret for session encryption.

Service names (local and production)

- `api` (Laravel PHP‑FPM)
  - Container: `clms-api`
  - Image: `${DOCKERHUB_NAMESPACE}/clms-api`
- `proxy` (Nginx → api)
  - Container: `clms-proxy`
  - Image: `${DOCKERHUB_NAMESPACE}/clms-proxy`
- `web` (Next.js)
  - Container: `clms-web`
  - Image: `${DOCKERHUB_NAMESPACE}/clms-web`

Frontend → API Bridge

- Calls to `/_api/bridge/...` in code are configured as `/api/bridge/...` and proxied to `${BACKEND_API_HOST}`.
- Compose sets `BACKEND_API_HOST=http://proxy:80` for the `web` container.
- File: `front-end/pages/api/bridge/[...path].js` (proxy, forwards `Authorization`).

Common Commands

- Bring up stack: `docker compose up -d --build`
- Tail logs: `docker compose logs -f web proxy api`
- Run tests (backend): `docker compose exec api php artisan test`
- Reset DB (dangerous): `docker compose down -v && docker compose up -d --build`

Environment

- Backend: set values in `back-end/.env` (copied from example). DB defaults come from Compose (Postgres 16).
- Frontend: `front-end/.env` can override `COOKIE_SECURE`, etc. For Docker, the cookie secret is provided via `.secrets/SECRET_COOKIE_PASSWORD`.

Networks

- Local (`compose.yml`): services attach to the `clms_dev` bridge network.
- Production (`compose.prod.yml`): services attach to the `clms_prod` bridge network.

Production Compose Override

- Use prebuilt images instead of building on the host: `compose.prod.yml`.
- Example: `docker compose -f compose.yml -f compose.prod.yml up -d`.
- Required env: `DOCKERHUB_NAMESPACE` and optionally `TAG` (defaults to `latest`), `SECRET_COOKIE_PASSWORD`.

Deployment (GitHub Actions)

- CI/CD workflow: `.github/workflows/ci-cd.yml` builds multi-arch images, pushes to Docker Hub, then deploys over SSH using the commit SHA tag.
  - Images: `${DOCKERHUB_NAMESPACE}/clms-web`, `${DOCKERHUB_NAMESPACE}/clms-api` (Laravel), `${DOCKERHUB_NAMESPACE}/clms-proxy` (Nginx) — tags: `latest`, commit `sha`, and tag ref.
  - Repo secrets:
    - `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `DOCKERHUB_NAMESPACE`
    - `SSH_HOST`, `SSH_USER`, `SSH_KEY`, `SSH_PORT` (optional), `REMOTE_PATH`
    - `SECRET_COOKIE_PASSWORD`
    - `DOMAIN_NAME` (optional; defaults to `clms.attara.dev` if unset)
    - `ACME_EMAIL` (optional; defaults to `admin@${DOMAIN_NAME}` if unset)
  - What deploy does (idempotent):
    - Writes `${REMOTE_PATH}/.env` with `DOCKERHUB_NAMESPACE`, `TAG`, `SECRET_COOKIE_PASSWORD`, `DOMAIN_NAME`, `ACME_EMAIL`.
    - Ensures `${REMOTE_PATH}/letsencrypt/acme.json` exists (mode 600) for Traefik ACME storage.
    - Runs `docker compose -f compose.prod.yml up -d --remove-orphans`.
    - Runs `php artisan migrate --force` and `php artisan db:seed --force` inside the `api` service.
  - After first deploy:
    - App is reachable at `https://<DOMAIN_NAME>` once DNS and certificates are ready.
    - Seeded login: `admin` / `admin` (change immediately).

Server Init

- Use the helper to bootstrap a fresh Ubuntu host with Docker and the required directory layout:
  - `sudo bash scripts/init-server.sh /opt/clms`
- It installs Docker Engine + compose plugin, creates `${REMOTE_PATH}/back-end/.env` with production defaults and a generated `APP_KEY`.
- It also creates `${REMOTE_PATH}/letsencrypt/` for Traefik's ACME storage (`acme.json`).
  - Traefik terminates TLS and obtains certificates automatically via Let's Encrypt (HTTP‑01 challenge on port 80) when your DNS points to the server.
- After running, configure GitHub repo secrets and push to `main` to deploy.

Provision EC2 with Terraform

- Directory: `infra/terraform`
- Prereqs: Terraform >= 1.3, AWS credentials set (e.g., `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`).
  - Creates: Ubuntu 24.04 EC2, security group (22,80,443), optional Elastic IP, and bootstraps Docker + deploy layout.
- Quick start:
  - `cd infra/terraform`
  - Create/update `terraform.tfvars` (example):
    - `aws_region = "us-east-1"`
    - `ssh_key_name = "your-existing-keypair"`  # or set `ssh_public_key = "ssh-ed25519 AAAA..."`
    - `allowed_ssh_cidr = "x.x.x.x/32"`         # your IP
    - `attach_eip = true`
    - `remote_path = "/opt/clms"`
    - `domain_name = "app.example.com"`         # optional; set DNS A record to public_ip/EIP
  - Run:
    - `terraform fmt -recursive`         # optional: format
    - `terraform init`                   # download providers
    - `terraform validate`               # sanity check
    - `terraform plan -out tfplan`       # review changes
    - `terraform apply tfplan`           # apply the plan (uses latest Ubuntu 24.04 AMI via AWS SSM)
    - `terraform output -json > outputs.json`  # optional: capture outputs
  - If using remote state (S3 backend), initialize with backend config:
    - `terraform init -migrate-state \`
      `-backend-config="bucket=your-bucket" \`
      `-backend-config="key=clms/terraform.tfstate" \`
      `-backend-config="region=us-east-1" \`
      `-backend-config="dynamodb_table=your-locks"`
  - Outputs include: `public_ip`, `ssh_user`, `ssh_command`, `remote_path`, `host`, and `https_url` (uses your `domain_name` if set, else the instance public DNS, else public IP).
  - Point your DNS A record for `domain_name` to `public_ip` (or the Elastic IP). Then use `https_url`.
  - To destroy: `terraform destroy`
- After apply, set CI secrets using the instance IP:
  - `SSH_HOST` = public IP
  - `SSH_USER` = `ubuntu`
  - `SSH_KEY` = contents of your private key (for `ssh_key_name`)
  - `REMOTE_PATH` = `/opt/clms` (or your chosen path)

API Highlights

- Users CRUD: `/api/admin/users` (auth via Sanctum Bearer token).
- Auth: `/api/login`, `/api/logout`.

Notes

- If the web app shows auth errors, confirm the Bearer token is set and the bridge endpoint is reachable.
- For local, ensure `proxy` and `api` containers are healthy before first login.

TLS via Traefik (production)

- Traefik is included in `compose.prod.yml` and terminates TLS for `https://<DOMAIN_NAME>`.
- Certificates: obtained automatically via Let’s Encrypt using HTTP‑01 challenge on entrypoint `web` (port 80); stored at `${REMOTE_PATH}/letsencrypt/acme.json`.
- Requirements:
  - DNS A/AAAA records for `<DOMAIN_NAME>` point to the server public IP.
  - Ports 80 and 443 open in your firewall / security group.
  - If using Cloudflare proxy (orange cloud), disable proxy (DNS only) or switch Traefik to DNS challenge.
- Troubleshooting:
  - `docker compose -f compose.prod.yml logs -f traefik | grep -i acme`
  - `curl -I http://<DOMAIN_NAME>` should return 301 to https.

Database and seeding (production)

- Deployment runs migrations and seeds a default admin user automatically.
- To rerun manually on the server:
  - `cd ${REMOTE_PATH}`
  - `sudo docker compose -f compose.prod.yml exec -T api php artisan migrate --force`
  - `sudo docker compose -f compose.prod.yml exec -T api php artisan db:seed --force`
