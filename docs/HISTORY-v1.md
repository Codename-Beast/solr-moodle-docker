# solr-moodle-docker — Version History v1 (2.0 – 2.5 Era)

This document preserves the complete history of the **v2.x generation** of
solr-moodle-docker. The project was later restructured and rebranded as
**v3.x (eLeDia-stack)** starting with v3.0.0 (2026-05-10).

> The version numbering scheme in this era was informal: releases were
> tagged manually, branch discipline was loose, and the CHANGELOG was
> partially reconstructed from git history. Dates marked with `*` are
> approximate based on commit timestamps.

---

## Timeline Overview

| Version | Date       | Theme                                      |
|---------|------------|--------------------------------------------|
| 2.0.0   | 2024-12-27 | Initial Docker release, single-tenant      |
| 2.1.0   | 2026-01-14 | GitLab CI, dynamic core name, refactor     |
| 2.1.1   | 2026-01-15 | Dockerfile simplification (powerinit.sh)   |
| 2.2.0   | 2026-01-15 | Security hardening, CI/CD improvements     |
| 2.2.1   | 2026-01-18 | CVE-2025-26519 musl hotfix (untagged)      |
| 2.2.2   | 2026-01-24 | Apache reverse proxy templates (untagged)  |
| 2.3.0   | 2026-03-27 | Moodle 4.x auth fix, password entropy      |
| 2.3.1   | 2026-03-28 | Solr 9.10.1 CVE update                     |
| 2.3.2   | 2026-03-30 | Security permission cleanup, monitoring rm |
| 2.4.0   | 2026-04-18 | CI trigger cleanup, code comment cleanup   |
| 2.5.0   | 2026-04-18 | Log volume documentation                   |

---

## [2.0.0] — 2024-12-27

Initial stable Docker release. The project started as a way to run Solr
for Moodle in a containerized setup with basic auth and health checks.

### Added
- Solr 9.10.0 support
- Moodle 4.1–5.x compatibility
- Automated setup with password generation (`generate_env.sh`)
- Multi-core support (single tenant per core)
- Prometheus + Grafana monitoring (optional, compose profiles)
- Comprehensive test suite (`run-tests.sh`)
- Moodle document testing script
- SELinux compatibility (Fedora/RHEL)
- Three user roles: `admin`, `moodle`, `support`
- Double SHA256 password hashing
- Automatic password change detection
- Health checks for all services
- Volume persistence

---

## [2.1.0] — 2026-01-14

Major refactoring. GitLab CI was introduced alongside the existing GitHub
Actions pipeline. The `.env` location was moved to the repo root.

### Added
- `.env.example` template for easy onboarding
- GitLab CI/CD pipeline (`.gitlab-ci.yml`): 5 stages — Validate, Build, Test, Security, Cleanup
- GitHub Actions CI/CD workflow as alternative
- Structured logging with log rotation (10 MB max, 3 files)
- Optional core name parameter for `setup` command
- `docs/GITLAB-QUICKSTART.md` and `docs/GITLAB-CI-CD-SETUP.md`

### Changed (Breaking)
- `.env` location moved from `eledia-workplace/` to repo root
- Container naming: `instance_service` → `instance-service` (e.g. `solr-solr`)
- `Dockerfile.init` renamed to `Dockerfile`
- `.gitignore` improved to exclude secrets and env files
- File permissions: `chmod 655` → `chmod 755` in init script
- Removed symlink logic from init container
- `docker-compose.yml` switched to `env_file` directive
- Grafana port changed from 3005 to 3000

### Fixed
- Container name variable resolution (`INSTANCE_NAME`)
- `.env` files now excluded from git tracking
- Directory permission corrections in init container

---

## [2.1.1] — 2026-01-15

### Fixed
- Dockerfile rewritten to use `powerinit.sh` (reduced from 273 to 30 lines)
- Removed embedded script approach in Dockerfile
- Dynamic core management working in CI/CD

### Removed
- Deprecated `create_core.sh` (functionality moved to `powerinit.sh`)

---

## [2.2.0] — 2026-01-15

Security hardening round. Monitoring stack tightened. CI/CD extended with
linting and vulnerability scanning.

### Security
- Alpine Linux base image pinned to SHA256 digest
- Grafana bind address changed from `0.0.0.0` to `127.0.0.1`
- Prometheus config permissions set to `600`
- File permission hardening: directories `750`, config files `640`, secrets `600`
- Secure temp file deletion: overwrite with zeros via `dd` before removal
- Resource limits added to all containers:
  - Solr: 2 CPUs / 4 GB RAM
  - Prometheus: 1 CPU / 1 GB RAM
  - Grafana: 1 CPU / 512 MB RAM

### Fixed
- Shellcheck SC2155 warnings (separated declarations from command substitutions)
- Shellcheck SC2086 warnings (quoted variable expansions)
- YAML indentation in GitHub Actions workflow
- Hadolint DL3059: consolidated multiple `RUN` instructions
- CPU limits reduced from 4 to 2 CPUs for GitHub Actions runner compatibility
- GitLab Enterprise: proper Docker-in-Docker config + fallback package install

### Changed
- GitHub Actions: added shellcheck, hadolint, yamllint, Trivy scanning
- GitHub Actions: split into lint / security-scan / test stages
- GitLab CI: `needs` dependencies, Trivy non-blocking, Docker daemon readiness
- Dockerfile reduced from 31 to 30 lines
- `develop22` branch added to CI triggers

### Added
- `.shellcheckrc`, `.hadolint.yaml`, `.yamllint` lint config files
- Negative tests for SQL injection, XSS, and related attack vectors
- Load/stress tests with concurrent request handling

---

## [2.3.0] — 2026-03-27

This release fixed a long-standing Moodle 4.x compatibility issue where
`SolrClient::system()` failed with HTTP 403 due to missing `config-read`
permission.

### Fixed
- `config-read` permission extended to `["admin", "support", "moodle"]`
  — fixes `is_server_ready()` 403 errors in Moodle 4.x
  - Root cause: Solr's `SystemInfoHandler` uses `CONFIG_READ_PERM`; custom
    path-level permissions do not apply to such built-in handlers
- Password generation switched from `openssl rand -hex 16` (hex, 32 chars)
  to `openssl rand -base64 36 | tr -d '/+=' | head -c 32` (alphanumeric, higher entropy)

### Changed
- `generate_env.sh`: `rand()` function updated to base64-based passwords
- `powerinit.sh`: fallback permissions corrected (config-read + full list)
- `security.json.template`: config-read role list corrected

### Verified
- 3x fresh deploy + 3x existing-stack test + 1x final fresh = 70/70 PASS

> After changes to `init/powerinit.sh` or `init/security.json.template`
> rebuild the init image: `docker compose build --no-cache eLeDia-solr-init`

---

## [2.3.1] — 2026-03-28

### Security
- Solr 9.10.0 → 9.10.1 (CVE fix update)
- All references updated: `docker-compose.yml`, `generate_env.sh`, GitHub Actions

---

## [2.3.2] — 2026-03-30

### Fixed
- `init/security.json.template` + `init/powerinit.sh`: `/admin/metrics`
  explicit path-permission for support user (403 fix)
- `init/generate_env.sh`: `.env` ownership transferred to host user
  (allows `docker compose` without sudo)
- `config-read` permission backfilled into `init/security.json.template`
  (was only fixed in `generate_env.sh` in v2.3.0)
- `core-admin-edit` permission removed for moodle user (security fix —
  Moodle does not need core admin write access)
- `powerinit.sh`: `forwardCredentials: false` added to inline fallback
- `powerinit.sh`: dead Prometheus config generation block removed
- `generate_env.sh`: monitoring variables removed
- `.env.example`: monitoring variables removed
- GitHub Actions: leading whitespace in inline `.env` blocks fixed
- `docker-compose.yml`: image tag `eLeDia-solr-init:v2.3` → `eLeDia-solr-init:v2.3.2`

### Added
- `docs/monitoring.md`: guide for Prometheus + Loki integration (external)

### Changed (Breaking)
- `docker-compose.yml`: Prometheus/Grafana/Exporter services **fully removed**
  — monitoring is now opt-in via separate `docker-compose.monitoring.yml`
- `docker-compose.yml`: resource limits read from `.env` (`${SOLR_CPU_LIMIT:-2}`)
- `.github/workflows/solr-testing.yml`: `feature/*` and `fix/*` branches added to push triggers
- `init/generate_env.sh`: `.env` created with `chmod 600` (root-readable only)

---

## [2.4.0] — 2026-04-18

Housekeeping release.

### Changed
- `init/powerinit.sh`: German code comment translated to English
- `.github/workflows/solr-testing.yml`: CI triggers narrowed to `main`
  and `feature/*` — removed `develop`, `develop22`, `fix/*`

---

## [2.5.0] — 2026-04-18

### Changed
- README: documentation added for mounting native Solr log directory
  (`/var/solr/logs/` via `docker-compose.override.yml`)
- `docker-compose.yml`: version label updated to v2.5.0

---

## [2.2.1] — 2026-01-18 (Hotfix)

Not formally tagged — committed directly to main as a hotfix.

### Security
- CVE-2025-26519 (musl/musl-utils): `apk upgrade --no-cache musl musl-utils`
  added to `Dockerfile` and `Dockerfile.init` to patch the vulnerability
  in Alpine 3.20 base images

---

## [2.2.2] — 2026-01-24 (Apache Templates)

Not formally tagged — merged from branch `feature/setup-gitlab-ci`.

### Added
- `apache/` directory: reverse proxy templates for multi-instance Solr setups
  behind an existing Apache server
  - `apache/solr-instance.conf.template` — VirtualHost template with
    placeholders (`{{INSTANCE_NAME}}`, `{{HOSTNAME}}`, `{{SOLR_PORT}}`)
  - `apache/ssl-common.conf` — shared SSL settings (inherits Let's Encrypt certs)
  - `apache/generate-apache-config.sh` — interactive config generator
    (194 lines, supports `--instance`, `--hostname`, `--port` params)
  - `apache/README.md` — setup guide with architecture diagram
- `.env.example`: `SOLR_HOSTNAME` variable added
- `.gitignore`: `apache/generated/` excluded

### Changed (GitLab CI)
- New `lint` stage added before security scans
- `apache-config-test` job: tests generator with multiple instances,
  verifies placeholder replacement, runs `httpd -t` syntax validation
  with mock SSL certificates
- GitLab CI and GitHub Actions test stages de-duplicated

---

## End of v1 / v2.x Era

The v2.x generation ended with v2.5.0 in April 2026. The codebase was
subsequently refactored into the **v3.x (eLeDia) generation**:

- v3.0.0 (2026-05-10): multi-tenant CLI, SolrCloud mode, `tenants.env`
- v3.x onward: eLeDia branding, modular scripts, ZooKeeper bootstrap,
  configset management, upgrade tooling, and CI hardening

See `CHANGELOG.md` for the v3.x history.
