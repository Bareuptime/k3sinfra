# Repository Guidelines

Contributors maintain Kubernetes- and baremetal-focused infrastructure for BareUptime. Favor reproducible scripts, declarative manifests, and changes that keep ArgoCD and Vault in sync across environments.

## Project Structure & Module Organization
- `apps/bareuptime-backend/` holds the Kustomize deployment (manifests, ingress, install prerequisites).
- `infra/k3s/` contains cluster add-ons such as Vault, cert-manager, Redis, RabbitMQ, and ArgoCD installers.
- `infra/baremetal/` provides baremetal installers for PostgreSQL with pgvector and ClickHouse (credentials land in `*-info.txt`).
- Shared docs live alongside the component they describe; update both README and scripts when altering behavior.

## Build, Test, and Development Commands
- `kubectl kustomize apps/bareuptime-backend` renders the full deployment for review.
- `kubectl apply --dry-run=server -k apps/bareuptime-backend` validates changes against a cluster API without persisting them.
- `bash infra/k3s/<component>/install.sh` installs supporting services (ensure idempotence per component).
- `./apps/bareuptime-backend/install-prerequisites.sh` installs Vault Secrets Webhook and verifies Vault/cert-manager readiness.

## Coding Style & Naming Conventions
- YAML: two-space indent, `---` between documents, and lowercase `kebab-case` names (`bareuptime-backend`, `api-bareuptime-tls`). Keep labels `app`, `environment`, and `managed-by` aligned with existing manifests.
- Shell: start scripts with `#!/bin/bash` and `set -euo pipefail`, prefer long-form `kubectl`/`helm` flags, and guard cluster assumptions (e.g., check namespaces before applying resources).
- Secrets use the `vault:secret/...#field` pattern—never commit resolved credentials.

## Testing Guidelines
- Run `kubectl diff -k apps/bareuptime-backend` or ArgoCD’s diff view before merging to understand live impact.
- Use `helm template` or `helm lint` when editing charts in `infra/k3s/`.
- Validate shell changes with `bash -n script.sh` and `shellcheck script.sh` when available.
- Ensure new resources include readiness probes or init checks similar to the existing `wait-for-database` container when appropriate.

## Commit & Pull Request Guidelines
- Follow the conventional commits style seen in history (`feat(scope): …`, `fix(component): …`); keep the subject ≤72 characters and describe the observable change.
- PRs should link related issues, summarize rollout steps (including required Vault secret updates), and note verification evidence (dry-run output, ArgoCD sync screenshot, or logs).
- Request review from infrastructure maintainers and attach any secrets rotation plan when credentials or policies change.

## Security & Configuration Tips
- All sensitive material must remain in Vault; update the relevant secret path in the docs when manifests start referencing a new key.
- Confirm cert-manager and Vault namespaces exist before applying manifests; document new dependencies in `infra/README.md`.
- Favor TLS-enabled endpoints and ensure Traefik middleware definitions stay aligned with ingress updates.
