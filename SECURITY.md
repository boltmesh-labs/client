# Security Policy

BoltMesh is a multi-region VPN platform composed of a FastAPI backend, a React/Vite web dashboard, a Go node agent that runs on WireGuard server nodes, and Terraform-provisioned AWS infrastructure. This document describes the security controls implemented across these components and how to report vulnerabilities.

## Supported Versions

We release patches for security vulnerabilities for the following versions:

| Version | Supported          |
| ------- | ------------------ |
| 1.x     | :white_check_mark: |
| 0.x     | :x:                |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues, pull requests, discussions, or bug-report templates.**

Use **GitHub Private Vulnerability Reporting** instead:

1. Open the [Security tab](https://github.com/boltmesh-labs/vpn-core/security) of this repository.
2. Select **Report a vulnerability**.
3. Fill in the advisory draft. Only repository maintainers can see it until disclosure is coordinated with you.

Please include:

- Description of the vulnerability and the affected component (`backend`, `frontend`, `node-agent`, `infra`)
- Version tag or commit SHA where the issue was observed
- Steps to reproduce, or a proof of concept (if applicable)
- Potential impact
- A suggested fix, if you have one

**Safe harbor**: we will not pursue, or support action against, anyone researching this project in good faith, provided they respect user privacy, avoid service degradation, neither exfiltrate nor destroy data, and use the channel above rather than exploiting a vulnerability beyond what is needed to demonstrate it.

Non-vulnerability security questions may be raised as public GitHub issues with the `security` label — without including sensitive detail.

## Automated Security Controls

CI runs on every push and pull request targeting `main`/`develop` through the workflows under `.github/workflows/`:

- **Trivy filesystem scanning** (`security.yml`): fails the build on CRITICAL findings and ignores advisories without available fixes. Results are uploaded to the GitHub Security tab as SARIF (even when the scan fails). Trivy also evaluates third-party dependencies from lockfiles (`uv.lock`, `go.sum`, `package-lock.json`). Suppressions are reviewed individually in `.trivyignore`, and each entry documents its rationale (e.g., an upstream version constraint in `fastapi-mail`).
- **Checkov static analysis of Terraform** (`infra.yml`): fails the pipeline on findings, with documented skips.
- **Pre-commit hooks** (`.pre-commit-config.yaml`): Ruff lint/format plus Pyright static typing for Python, ESLint/Prettier for JavaScript, Terraform fmt/validate, Packer validate, and whitespace/YAML/large-file/merge-conflict guards.
- **Test coverage gates**: pytest enforces a minimum of 80% backend coverage (`fail_under = 80`); frontend Vitest runs with coverage in CI.
- **Release integrity**: the Go node agent is built by `make all` (vet + test + cross-compile) into `bin/` with SHA-256 checksums; CI verifies `sha256sum -c checksums.txt` before publishing artifacts to GitHub Releases.
- **CI secret hygiene**: workflows declare explicit least-privilege `permissions:` blocks, and cloud credentials are supplied only through GitHub Actions secrets — never committed to the repository.

Note: automated dependency-update automation (e.g., Dependabot) is **not yet configured** in this repository. Updates land through normal review, gated by the Trivy scan above.

## Application Security (Backend)

- **Password storage**: bcrypt hashing with a work factor of 12. Inputs beyond bcrypt's 72-byte limit are rejected outright rather than silently truncated (`app/core/security/passwords.py`).
- **Timing-equalized authentication**: login verifies against a pre-computed dummy hash so non-existent accounts and wrong passwords are indistinguishable by response time; password-reset requests are deliberately neutral (tokens are minted against fixed sentinel keys and never emailed) to prevent account enumeration.
- **Sessions**: short-lived JWT access tokens with rotating refresh tokens guarded by explicit reuse-detection and rotation-race errors (`TokenReusedError`, `TokenRotationRaceError`); sessions are Redis-backed and can be revoked server-side at any time. Account activation tokens are minted *before* the database commit so a Redis failure rolls back consistently, and confirmed password resets revoke all active sessions.
- **Refresh-token cookie**: HttpOnly, Secure, scoped to the `/v1/auth` path. SameSite/Secure derive from the environment (`lax` for same-site development; `None` in cross-site production, which pairs with the origin check below).
- **CSRF mitigation**: state-changing, cookie-authenticated requests whose `Origin` header is not on the CORS allowlist are rejected with 403 (`require_safe_origin`), closing the cross-site request forgery window created by `SameSite=None` cookies. Non-browser clients (curl, native apps) that omit the header are unaffected.
- **CORS**: strict allowlists of origins, methods, and headers — nothing is wildcarded; credentials are allowed only for explicitly listed origins.
- **OAuth**: Google/GitHub sign-in delegated to Authlib clients using authorization-code flows with provider metadata discovery.
- **Input validation and SQL safety**: Pydantic validates every request/response boundary; data access goes exclusively through SQLAlchemy parameterized queries — no string-built SQL.
- **Client IP trust**: `TRUST_PROXY_HEADERS` defaults to false, so rate limiting keys off the direct connection unless the backend intentionally runs behind a trusted reverse proxy that sets `X-Forwarded-For`.

See [backend/README.md](backend/README.md) for endpoint-level documentation.

## Node-Agent Control Plane

- Agent endpoints under `/v1/control-plane/` authenticate with short-lived per-node JWTs presented as `Authorization: Bearer <node JWT>`. Bootstrap secrets are stored as HMAC-SHA256 digests peppered with `BOOTSTRAP_SECRET_PEPPER` (minimum 32 characters) and are used only during enrollment.
- Zero-trust self-registration (`register`) has no shared secret. **AWS IID mode** (EC2 nodes): the agent posts its hypervisor-signed Instance Identity Document + IMDSv2 PKCS#7 signature; the backend verifies the signature with `openssl` against pinned signer fingerprints (`AWS_IID_SIGNER_FINGERPRINTS`, fail-closed when unconfigured), binds the verified `accountId` to `AWS_IID_ACCOUNT_ID`, and requires `instanceId == server_name` and `region == region_id`. **Per-server secret mode** (manual nodes): the admin-issued one-liner embeds a single-server `vpn_boot_...` secret (shown once, stored hashed); the node presents it as `Authorization: Bearer`, bound to its own server row with a rolling `MANUAL_BOOTSTRAP_SECRET_TTL_DAYS` expiry refreshed on every boot — blast radius is one server. Every 401 (`BOOTSTRAP_IDENTITY_INVALID`, `BOOTSTRAP_TOKEN_INVALID`) is definitive. Node registration of a *live* node — any row with a heartbeat inside the staleness window, whatever its status label — is refused so a stolen bootstrap credential cannot refresh a node's JWT or extend its bootstrap expiry by impersonating its server name; the agent treats that specific conflict as retryable and waits out the staleness window (the 409 carries a `Retry-After` hint with the remaining staleness, so fast reboots converge without operator intervention).
- Agents refresh their short-lived node JWTs periodically and retry rapidly on renewal failures to maintain authentication before expiration, minimizing the validity window of any compromised credential.
- Agent binaries are distributed exclusively through official GitHub Releases with SHA-256 checksums (verified in CI).

See [node-agent/README.md](node-agent/README.md) for the agent's full documentation.

## Rate Limiting & Abuse Prevention

Two independent layers protect the platform:

1. **Application tier** — Redis-shared rate-limit buckets (pyrate-limiter, Lua-scripted for cross-replica correctness):

   | Scope                 | Limit       |
   | --------------------- | ----------- |
   | Login / auth attempts | 10 req/min  |
   | Token refresh         | 30 req/min  |
   | Node-agent sync       | 30 req/min  |
   | Admin APIs            | 60 req/min  |
   | Everything else       | 100 req/min |

   Exceeding a bucket returns HTTP 429 (`TooManyRequestsError`).

2. **Edge tier** — AWS WAF v2 Web ACLs (a CloudFront-scoped ACL and a regional ACL attached directly to the ALB) evaluate AWS managed rule groups — `CommonRuleSet`, `KnownBadInputsRuleSet`, and `AmazonIpReputationList` — preceded by an IP rate-based rule that absorbs volumetric floods before the managed rules run. The threshold (requests per IP per 5-minute window) is configurable per environment.

## Cryptography & Data Protection

- **Password hashing**: bcrypt, cost factor 12 (see above).
- **TLS everywhere**: ALB HTTPS listeners enforce `ELBSecurityPolicy-TLS13-1-2-2021-06`; CloudFront requires TLS ≥ 1.2 with redirect-to-HTTPS viewer policies; CloudFront→ALB origin connections are HTTPS-only; plain HTTP is redirected at every layer.
- **Gateway TLS**: the Lightning (CLN REST) gateway verifies its peer certificate against `LIGHTNING_CA_CERT`; insecure mode exists (`LIGHTNING_TLS_INSECURE`) but defaults to false.
- **Secrets management**: development secrets live only in local environment variables (never committed); production secrets reside in AWS Secrets Manager under customer-managed KMS keys and are injected directly into ECS task definitions. VPN nodes hold no shared secret: EC2 nodes authenticate with their hypervisor-signed instance identity, and manual nodes hold only their own per-server bootstrap secret (hashed server-side). Terraform receives sensitive values via `TF_VAR_*` rather than plaintext tfvars (values still reach the remote state — the caveat is documented in [infra/README.md](infra/README.md)); the RDS master password uses the RDS-managed Secrets Manager secret and never touches state.
- **Backups and logs at rest**: RDS automated backups retain between 1 and 35 days (validated by configuration constraints); VPC flow logs, ALB access logs, and Terraform state are encrypted with dedicated customer-managed KMS keys.

## Infrastructure Security

- **Network segmentation**: VPC public/private subnets with least-privilege security groups isolating the public ALB, WireGuard EC2 nodes, application containers, ARQ workers, ElastiCache, and database subnets.
- **No SSH**: there are no port 22 ingress rules and no interactive shell path on EC2 nodes — immutable golden AMIs are replaced, not logged into — and IMDSv2 is required.
- **Stateless serving tiers**: frontend and backend run on ECS Fargate; private egress to AWS services (ECR, S3, Secrets Manager, CloudWatch) travels over VPC endpoints instead of NAT gateways.
- **Audit trails**: CloudTrail records governance events to a compliance S3 bucket; VPC flow logs and ALB access logs land in KMS-encrypted S3; CloudWatch log groups use customer-managed CMKs.
- **Edge origin isolation** (when CloudFront fronts the stack): the ALB security group accepts traffic only from the CloudFront origin-facing managed prefix list, and every origin request must carry the shared `X-Origin-Verify` secret header — ALB listener rules return 403 otherwise, preventing direct-to-origin bypass.
- **Hardened node images**: WireGuard node AMIs are built from Packer golden images, with post-deployment checklists covering IMDSv2, no SSH ingress, and security-group review.

## HTTP Security Headers

The production frontend container sets the following headers on all document and asset responses:

   X-Frame-Options: SAMEORIGIN
   X-Content-Type-Options: nosniff
   Referrer-Policy: strict-origin-when-cross-origin
   Permissions-Policy: camera=(), microphone=(), geolocation=()

Known gap: the API tier does not currently emit `Strict-Transport-Security` or `Content-Security-Policy` headers. Operators fronting the API with their own CDN or reverse proxy should set them at the edge; adding them in-tree is planned work.

## Response Time

We aim to acknowledge every vulnerability report within **48 hours** and will keep reporters updated throughout triage and remediation. Thank you for your patience.

## Disclosure Policy

1. We acknowledge receipt of your vulnerability report.
2. We investigate and determine the severity.
3. We develop and test a fix.
4. We release a patched version.
5. We publicly disclose the vulnerability after a reasonable delay (typically 90 days), crediting the reporter where desired.

## Best Practices for Operators

If you deploy BoltMesh components, please:

1. **Run supported versions** — update promptly when patch releases ship.
2. **Verify node-agent downloads** — obtain binaries only from official GitHub Releases and confirm `sha256sum -c checksums.txt`.
3. **Protect signing secrets** — `SECRET_KEY`, `REFRESH_SECRET_KEY`, and `NODE_SECRET_KEY` must be distinct, strong random values (minimum 32 characters each). Pin your AWS IID trust (`AWS_IID_ACCOUNT_ID` plus `AWS_IID_SIGNER_FINGERPRINTS`) before enrolling EC2 nodes, and re-issue a server's per-server bootstrap secret (`POST /servers/{id}/bootstrap-secret`) if its one-liner may have leaked.
4. **Keep gateway TLS verification on** — do not set `LIGHTNING_TLS_INSECURE=true` outside throwaway development environments.
5. **Configure proxies honestly** — enable `TRUST_PROXY_HEADERS=true` only behind a reverse proxy you control that sets `X-Forwarded-For`; otherwise rate limiting keys off direct connections.
6. **Pin your origins** — point `CORS_ALLOW_ORIGINS` at exactly your deployed origins; firewall administrative endpoints away from the public internet where possible.
7. **Isolate development crypto services** — the regtest bitcoind, lightningd, monerod, and monero-wallet-rpc containers in docker-compose exist for local development only and must never be reachable from untrusted networks.
8. **Monitor** — scrape the `/health` endpoint (which reports Redis, database, and payment-gateway status) and alert on structured JSON logs.
9. **Back up and rehearse** — configure an appropriate `db_backup_retention` value and periodically test restores.
10. **Review CI changes as security-sensitive code** — audit modifications to `.github/workflows/` and `.trivyignore` with the same scrutiny as source changes.

## Contact

Security-related questions that are **not** vulnerability reports may be raised as public GitHub issues with the `security` label, or discussed privately via a drafted advisory on the [Security tab](https://github.com/boltmesh-labs/vpn-core/security).

Thank you for helping keep BoltMesh and our users safe! 🔒
