# BoltMesh Deployment

This document covers deploying BoltMesh: the local Docker Compose development stack, the production AWS infrastructure provisioned with Terraform, the backend container and ARQ workers, and the Go VPN node agent lifecycle. For contribution guidelines see [CONTRIBUTING.md](CONTRIBUTING.md); for the API surface see [backend/README.md](backend/README.md).

## Contents

- [1. Local Development Stack](#1-local-development-stack)
- [2. Production on AWS (Terraform)](#2-production-on-aws-terraform)
- [3. Backend & Worker Containers](#3-backend--worker-containers)
- [4. VPN Node Agent](#4-vpn-node-agent)
- [5. CI/CD Pipeline](#5-cicd-pipeline)

## 1. Local Development Stack

### Prerequisites

- Podman and Podman Compose
- Python 3.13+, Go 1.26+, Node.js 22+ (for local tooling and tests)

### Steps

1. Clone the repository:

   ```bash
   git clone https://github.com/boltmesh-labs/vpn-core
   cd vpn-core
   ```

2. Create the backend environment file:

   ```bash
   cp backend/.env.example backend/.env
   ```

   The stack will not start without `backend/.env` — compose loads it via `env_file`. See the configuration table in [backend/README.md](backend/README.md) for all variables.

3. Start the stack:

   ```bash
   podman-compose up -d
   ```

   This starts the API at `http://localhost:8000` (OpenAPI at `/docs`), the frontend at `http://localhost:5173`, PostgreSQL (:5432), Redis (:6379), and regtest Bitcoin/Lightning/Monero services.

4. Initialize the database:

   ```bash
   podman-compose exec backend alembic upgrade head
   podman-compose exec backend python -m scripts.generate_samples
   ```

   This applies migrations and seeds the default subscription plans.

The ARQ worker runs as its own container (`arq app.worker.WorkerSettings`) and is started automatically by compose. It handles invoice reconciliation (every minute) and subscription expiry (every 10 minutes).

## 2. Production on AWS (Terraform)

Production infrastructure lives under `infra/aws/terraform/` and is provisioned as AWS resources: VPC with public/private subnets, an Application Load Balancer (HTTP → HTTPS), ECS Fargate clusters for the frontend and backend, a multi-AZ RDS database, optional WireGuard VPN endpoints, and KMS-encrypted S3 buckets for VPC Flow Logs and access logs. See [infra/README.md](infra/README.md) for the full architecture and module reference.

### AWS Prerequisites

- Terraform >= 1.15.8
- Packer >= 1.10.0 (for building Golden AMIs)
- AWS CLI configured with appropriate credentials
- Container images for the frontend and backend pushed to a registry the cluster can pull from

### Build Golden AMIs (Packer)

Before deploying the WireGuard VPN infrastructure, build the read-only Golden AMI:

```bash
cd infra
make packer-init
make packer-validate ENV=dev
make packer-build ENV=dev
```

This builds a hardened AMI with read-only root filesystem (`ro`) and tmpfs mounts for runtime state. The AMI is copied to all deployment regions via `ami_regions`.

### Remote state

Remote state uses an S3 bucket with S3-native locking (no DynamoDB required). Set it up once per AWS account:

```bash
cd infra
make configure   # creates S3 bucket with versioning, encryption, and public access block
```

The bucket name is configured via `STATE_BUCKET` (default: `boltmesh-tf-state-global`).

### Deploy

Each environment is a self-contained directory under `infra/aws/terraform/environments/` (`dev`, `staging`, `global`; `prod` is added the same way). Every environment has its own `terraform.tfvars` (gitignored — it carries secrets):

```bash
cd infra
make init ENV=staging    # terraform -chdir=environments/staging init
make plan ENV=staging    # terraform plan -var-file=terraform.tfvars
make apply ENV=staging   # terraform apply -var-file=terraform.tfvars
```

The Makefile targets are env-aware: `make <target> ENV=dev|staging|prod|global`.

### Staging

Staging is a near-full copy of the dev environment under `infra/aws/terraform/environments/staging/`, parameterized by its own `terraform.tfvars` — set `environment = "staging"` and tune the feature toggles/sizes (see `infra/aws/terraform/terraform.tfvars.example` for the full variable reference). Golden AMIs use `infra/aws/packer/vpn-golden-ami/pkrvars/staging.pkrvars.hcl`.

Feature toggles `enable_frontend`, `enable_backend`, `enable_database`, and `enable_vpn` let you deploy individual tiers.

### Post-deploy

1. **Run database migrations** against the deployed database before/while rolling out the backend image:

   ```bash
   alembic upgrade head
   ```

2. **Seed subscription plans** if this is a fresh database:

   ```bash
   python -m scripts.generate_samples
   ```

3. **Register VPN nodes** — create server records for your WireGuard endpoints so the node agent can bootstrap (see [Section 4](#4-vpn-node-agent)).

### Operations

| Command | Purpose |
| - | - |
| `make output` | Show deployment outputs (ALB URL, RDS endpoint, etc.) |
| `make state-list` / `make state-show resource=<res>` | Inspect Terraform state |
| `make destroy` | Destroy all infrastructure (destructive, asks for confirmation) |
| `make unlock LOCK_ID=<id>` | Force-unlock stale state locks |
| `make refresh` / `make console` | Advanced Terraform workflows |

## 3. Backend & Worker Containers

The backend image is built from `backend/Dockerfile` (multi-stage, `uv`-installed dependencies on `python:3.13-slim`, runs as a non-root user). The container runs gunicorn with 4 uvicorn workers (`gunicorn.conf.py`) and exposes a `/health` health check.

### Backend Configuration

The backend reads all configuration from environment variables (see the table in [backend/README.md](backend/README.md)). Critical values in production:

- `SECRET_KEY` / `REFRESH_SECRET_KEY` / `NODE_SECRET_KEY` — JWT signing secrets (must be strong random values, distinct from each other)
- `BOOTSTRAP_SECRET_PEPPER` — pepper for node agent API key HMAC
- `AWS_IID_ACCOUNT_ID` / `AWS_IID_SIGNER_FINGERPRINTS` — zero-trust EC2 bootstrap trust (fingerprints required for IID mode)
- `MANUAL_BOOTSTRAP_SECRET_TTL_DAYS` — rolling expiry for per-server manual-node bootstrap secrets
- `DATABASE_URL` — async PostgreSQL connection string
- `REDIS_HOST` / `REDIS_PORT` — Redis is required for sessions, node key caching, and bootstrap tokens
- `LIGHTNING_GATEWAY_URL` / `LIGHTNING_API_KEY`, `MONERO_RPC_URL` / `MONERO_RPC_USER` / `MONERO_RPC_PASSWORD` — payment gateway credentials
- `CORS_ALLOW_ORIGINS` / `FRONTEND_URL` — must point at the deployed frontend
- `MAIL_*` — SMTP settings for activation and password-reset emails

### Worker

Run the ARQ worker as a separate container/process with the same environment as the backend:

```bash
arq app.worker.WorkerSettings
```

It is required for invoice settlement and subscription lifecycle to work in production.

## 4. VPN Node Agent

`node-agent` is a statically compiled Go binary (built with `CGO_ENABLED=0`) that runs on each WireGuard server node.

### Build

```bash
cd node-agent
make build   # cross-compiles amd64 + arm64 into bin/ with checksums.txt
```

On `v*` git tags, CI builds and publishes these artifacts as a GitHub release automatically (see [Section 5](#5-cicd-pipeline)).

### Deploy to a node

Nodes self-register — there is no manual config or keypair step:

1. Install the binary (e.g. `/usr/local/bin/node-agent`). The agent is stateless: `node-agent bootstrap` registers in-process and holds the node JWT plus its ephemeral WireGuard key in memory for the process lifetime, re-registering on every start.
2. Provide the bootstrap inputs — manual nodes via the persistent `/etc/node-agent/bootstrap.env` seed (`API_BASE_URL` as the bare backend host + per-server `NODE_BOOTSTRAP_SECRET`); EC2 nodes need nothing on disk (the agent fetches user-data and the hypervisor-signed `INSTANCE_IDENTITY_DOCUMENT` + `INSTANCE_IDENTITY_SIGNATURE` from IMDSv2) — and run `node-agent bootstrap`.
3. Bootstrap posts `POST /v1/control-plane/register/manual` (manual nodes, with `Authorization: Bearer <per-server secret>`) or `POST /v1/control-plane/register/ami` (EC2 nodes, with the hypervisor-signed identity pair in the body). On success the backend returns a short-lived node JWT and the region's WireGuard parameters; the agent opens the returned WG port as a firewalld runtime rule, then the daemon uses `Authorization: Bearer <node JWT>` for heartbeat, peer sync, and token renewal. Re-mint credentials are retained in memory only.

### Node Agent Configuration

| Variable | Flag | Default | Description |
| - | - | - | - |
| `HEALTH_CHECK_ADDR` | `--health-addr` (daemon only) | `127.0.0.1:8080` | Health check server address |
| `LOG_LEVEL` | — (daemon only) | `INFO` | Log level (DEBUG, INFO, WARN, ERROR) |
| `NODE_OS` | — (`bootstrap` only) | `rocky` | OS reported to the control plane |

Bootstrap inputs are platform files, not environment: the manual seed file (`API_BASE_URL`, `NODE_BOOTSTRAP_SECRET`) or EC2 user-data (`API_BASE_URL`, `REGION_ID`, `REGION_NAME`, `PUBLIC_IP`, `ENDPOINT`, `TUNNEL_IP`) plus IMDS instance identity. `ENDPOINT` must be a bare host/IP without port.

### Runtime behavior

- **Heartbeat**: telemetry (uptime, active peers, RX/TX bytes) every 30 seconds
- **Peer sync**: desired peer state fetched from the backend and applied to the WireGuard interface every 30 seconds
- **Token refresh**: requests a new short-lived node JWT every 10 minutes and updates the in-memory config (stateless — nothing is written to disk)
- **Health**: `/health` and `/version` served on `127.0.0.1:8080`

## 5. CI/CD Pipeline

`.github/workflows/ci.yml` runs on pushes to `main`/`develop`, pull requests, and `v*` tags:

| Job | Checks |
| - | - |
| `backend-tests` | Ruff lint, `ruff format --check`, Pyright, Pytest |
| `frontend-tests` | `npm ci`, `npm run lint`, `npm run test`, `npm run build` |
| `node-agent-build` | `go test -v ./...`, `make all` with tag as version, `sha256sum -c` verification, artifact upload |
| `security-scan` | Trivy filesystem scan (fails on CRITICAL/HIGH, respects `.trivyignore`) |
| `publish-release` | On `v*` tags only: downloads node-agent binaries and publishes them as a GitHub release with generated release notes |

Terraform validation (`make fmt-check`, `terraform validate`) runs locally via `make validate ENV=dev` before pushing; there is no dedicated CI job for it.

## Troubleshooting

- **Backend won't start**: `backend/.env` is missing or incomplete — compose loads it via `env_file`.
- **Migrations not applied**: run `alembic upgrade head` in the backend container before starting traffic.
- **Node agent can't register (401)**: the credential was rejected — a wrong/expired per-server `NODE_BOOTSTRAP_SECRET` (re-issue it with `POST /servers/{id}/bootstrap-secret`), a failed instance-identity verification (`BOOTSTRAP_IDENTITY_INVALID`: unconfigured signer fingerprints, account/region/name binding mismatch, or bad PKCS#7).
- **Node agent can't register (422)**: the payload failed validation — common cause is `ENDPOINT` containing a port (`host:51820`); it must be a bare host/IP (the WG port comes from the register response).
- **Node agent can't reach the backend**: verify `API_BASE_URL` is reachable from the node (bare host or with a trailing `/v1` — both are accepted).
- **Payments stuck on `pending`**: confirm the worker container is running and Redis is reachable from it.
