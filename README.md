# CLMS

Full-stack app with a **Laravel API** (PHP 8.3, Postgres, Redis) and a **Next.js frontend**.  
Docker Compose orchestrates services for local dev and deployment.

- Live: [https://clms.attara.dev](https://clms.attara.dev)

---

## Quick Start (Local Dev)

### Prereqs

- Docker Desktop 4.24+

### Setup

```bash
# 1. Create cookie secret
mkdir -p .secrets && openssl rand -base64 48 > .secrets/SECRET_COOKIE_PASSWORD

# 2. Copy backend env and start
cp back-end/.env.example back-end/.env
docker compose up -d --build

# 3. Generate key, migrate & seed
docker compose exec api php artisan key:generate
docker compose exec api php artisan migrate --seed
````

### Open

- Web: [http://localhost:3000](http://localhost:3000)
- API Proxy: [http://localhost:8000](http://localhost:8000)

### Login (seeded)

- Username: `admin`
- Password: `admin`

---

## Common Commands

- Bring up stack:
  `docker compose up -d --build`
- Logs:
  `docker compose logs -f web proxy api`
- Backend tests:
  `docker compose exec api php artisan test`
- Reset DB:
  `docker compose down -v && docker compose up -d --build`

---

## Deployment

- Production runs with `compose.prod.yml` using prebuilt images.
- CI/CD:
  - `.github/workflows/build.yml` builds multi-arch images and pushes to Docker Hub.
  - `.github/workflows/deploy.yml` deploys via SSH.
  - `.github/workflows/rollback.yml` handles deploy rollbacks via SSH.
- TLS via Traefik with automatic Let’s Encrypt certs.

See [docs/DEPLOY.md](docs/DEPLOY.md) for full details.
