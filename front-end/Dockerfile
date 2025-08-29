# ---- 0) Base ----
ARG NODE_VERSION=20-bookworm-slim

# ---- 1) Deps ----
FROM node:${NODE_VERSION} AS deps
WORKDIR /app

# Smooth over peer-deps for React 19 RC during install (safe to keep as ENV)
ENV NEXT_TELEMETRY_DISABLED=1 \
  NPM_CONFIG_LEGACY_PEER_DEPS=true

# Copy only manifests to leverage caching
# (When copying more than one source, end dest with /)
COPY package.json package-lock.json* ./

# Install dependencies (prefer npm ci if lockfile exists)
RUN if [ -f package-lock.json ]; then npm ci; else npm i; fi


# ---- 2) Build (standalone) ----
FROM node:${NODE_VERSION} AS builder
WORKDIR /app

# Production build (no secrets here!)
ENV NODE_ENV=production \
  NEXT_TELEMETRY_DISABLED=1 \
  NPM_CONFIG_LEGACY_PEER_DEPS=true

# Bring deps and source
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# ⛳ Use BuildKit secret for SECRET_COOKIE_PASSWORD only during this RUN.
#    It is available at /run/secrets/secret_cookie_password and never stored in layers.
#    We export it for the duration of the build command so Next can collect page data.
RUN --mount=type=secret,id=secret_cookie_password \
  bash -lc 'export SECRET_COOKIE_PASSWORD="$(cat /run/secrets/secret_cookie_password)"; npm run build'


# ---- 3) Runtime (standalone) ----
FROM node:${NODE_VERSION} AS runner
WORKDIR /app

ENV NODE_ENV=production \
  NEXT_TELEMETRY_DISABLED=1 \
  PORT=3000 \
  HOSTNAME=0.0.0.0

# Drop root
RUN useradd -m nextjs
USER nextjs

# Copy the minimal server + assets from standalone build
COPY --from=builder --chown=nextjs:nextjs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nextjs /app/.next/static ./.next/static
COPY --from=builder --chown=nextjs:nextjs /app/public ./public

EXPOSE 3000
CMD ["node", "server.js"]
