# Changelog

[Keep a Changelog](https://keepachangelog.com/en/1.0.0/) | [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## [2.3.2] — 2026-03-30

### Behoben
- `init/security.json.template` + `init/powerinit.sh`: `/admin/metrics` explizite Path-Permission fuer Support-User ergaenzt (403-Fix)
- `init/generate_env.sh`: `.env` Ownership an Host-User uebergeben (docker compose ohne sudo)
- **`config-read` Permission auf `["admin", "support", "moodle"]` erweitert** — behebt `is_server_ready()` 403-Fehler in Moodle 4.x
  - Betrifft: `init/security.json.template` und `init/powerinit.sh` (Fallback-Permissions)
  - Root cause: analog zu v2.3.0-Fix in generate_env.sh, aber init-Templates waren noch nicht aktualisiert
- **`core-admin-edit` Permission fuer moodle-User entfernt** — Sicherheitsfix, Moodle benoetigt keinen Core-Admin-Schreibzugriff
  - Betrifft: `init/security.json.template` und `init/powerinit.sh` (Fallback-Permissions)
- `init/powerinit.sh`: `forwardCredentials: false` in Inline-Fallback ergaenzt (Konsistenz mit security.json.template)
- `init/powerinit.sh`: Prometheus-Config-Generierungsblock entfernt (toter Code — Volume nicht gemountet)
- `init/generate_env.sh`: Monitoring-Variablen entfernt (Prometheus/Grafana nicht im Stack)
- `.env.example`: Monitoring-Variablen entfernt
- `.github/workflows/solr-testing.yml`: Fuehrende Whitespaces in inline `.env`-Bloecken behoben
- `docker-compose.yml`: Image-Tag `solr-init:v2.3` → `solr-init:v2.3.2`

### Hinzugefuegt
- `docs/monitoring.md` — Anleitung fuer Prometheus- und Loki-Integration (Groundwork, kein Service im Stack)

### Geaendert
- `docker-compose.yml`: Resource Limits (`cpus`, `memory`) werden aus `.env` gelesen statt hardcoded (`${SOLR_CPU_LIMIT:-2}` etc.)
- `docker-compose.yml`: Prometheus/Grafana/Exporter-Services vollständig entfernt (Breaking Change für bestehende Monitoring-Setups). Integration weiterhin möglich via separater `docker-compose.monitoring.yml` (siehe `docs/monitoring.md`)
- `.github/workflows/solr-testing.yml`: `feature/*` und `fix/*` Branches zu push-Triggern hinzugefügt
- `init/generate_env.sh`: `.env` wird mit `chmod 600` erstellt (nur root lesbar), `chgrp docker` entfernt
- `README.md`: Versionsreferenzen auf v2.3.2, Monitoring-Abschnitt mit Nutzungsanleitung aktualisiert

---

## [2.3.1] - 2026-03-28

### Security
- **Solr 9.10.0 -> 9.10.1**: CVE-Fix-Update; alle Referenzen auf 9.10.1 aktualisiert

### Changed
- `docker-compose.yml`: SOLR_VERSION Default auf 9.10.1
- `init/generate_env.sh`: SOLR_VERSION auf 9.10.1
- `.github/workflows/solr-testing.yml`: Trivy-Scan auf `solr:9.10.1`
- `README.md`: Versionsreferenzen auf v2.3.1 / Solr 9.10.1

---

## [2.3.0] - 2026-03-27

### Fixed
- **`config-read` Permission auf `["admin", "support", "moodle"]` erweitert** — behebt `is_server_ready()` 403-Fehler in Moodle 4.x
  - Root cause: Solrs `SystemInfoHandler` deklariert sich als `CONFIG_READ_PERM`. Custom Path-Permissions greifen nicht für solche Handler. Moodles `SolrClient->system()` → `/solr/<core>/admin/system/` benötigte `config-read`-Berechtigung.
- **Passwort-Generierung** von `openssl rand -hex 16` (hex, 32 Zeichen) auf `openssl rand -base64 36 | tr -d '/+=' | head -c 32` (alphanumerisch, höhere Entropie) umgestellt

### Changed
- `generate_env.sh`: `rand()` Funktion auf base64-basierte Passwörter umgestellt
- `powerinit.sh`: Fallback-Permissions korrigiert (config-read + vollständige Liste)
- `security.json.template`: config-read Role-Liste korrigiert

### Tests
- Deploy-Testsuite hinzugefügt: 3x Fresh Deploy + 3x Bestandstest + 1x Final Fresh = 70/70 Tests bestanden

> ⚠️ Nach Änderungen an `init/powerinit.sh` oder `init/security.json.template` muss das Init-Image neu gebaut werden:
> ```bash
> docker compose build --no-cache solr-init
> ```

---

## [2.2.0] - 2025-01-15

### Security
- **Alpine Linux SHA256 pinning**: Base image now pinned to specific digest for security
- **Grafana bind address**: Changed from `0.0.0.0` to `127.0.0.1` to prevent external access
- **Prometheus config permissions**: Set to `600` for secure credential storage
- **File permissions hardening**:
  - Directories: `750` (was `755`)
  - Config files: `640` (was `644`)
  - Secret files: `600` (was `644`)
- **Secure temp file deletion**: Overwrite with zeros before deletion using `dd`
- **Resource limits**: Added CPU and memory limits for all containers to prevent DoS
  - Solr: 2 CPUs / 4GB RAM (limits), 0.5 CPU / 2GB RAM (reservations)
  - Prometheus: 1 CPU / 1GB RAM (limits), 0.25 CPU / 256MB RAM (reservations)
  - Grafana: 1 CPU / 512MB RAM (limits), 0.25 CPU / 128MB RAM (reservations)

### Fixed
- **Shellcheck SC2155 warnings**: Separated variable declarations from command substitutions in all bash scripts
- **Shellcheck SC2086 warnings**: Properly quoted all variable expansions
- **YAML indentation**: Fixed GitHub Actions workflow to use consistent 6-space indentation for step items
- **Dockerfile DL3059 warning**: Consolidated multiple RUN instructions to reduce image layers
- **CPU limits for CI/CD**: Reduced from 4 to 2 CPUs for GitHub Actions runner compatibility
- **GitLab Enterprise compatibility**: Added proper Docker-in-Docker configuration and fallback package installation

### Changed
- **GitHub Actions workflow**:
  - Added comprehensive code quality checks (shellcheck, hadolint, yamllint)
  - Added Trivy security vulnerability scanning for both init and Solr images
  - Split testing into lint, security-scan, and test stages
  - Added matrix testing for multiple core configurations
  - Added automated password generation testing
  - Added dynamic core management testing
- **GitLab CI/CD pipeline**:
  - Enhanced security-scan stage with Docker-in-Docker support
  - Added `needs` dependencies for proper job ordering
  - Added fallback package installation for different Ubuntu versions
  - Set Trivy scans to non-blocking mode
  - Added docker daemon readiness checks
- **Dockerfile**: Reduced from 31 to 30 lines by consolidating RUN commands
- **Branch triggers**: Added `develop22` to CI/CD branch triggers

### Added
- **CI/CD configuration files**:
  - `.shellcheckrc`: Shellcheck configuration to disable false positives
  - `.hadolint.yaml`: Hadolint configuration for Dockerfile linting
  - `.yamllint`: Yamllint configuration for YAML validation
- **Monitoring**: Prometheus configuration now includes documentation about plaintext credential limitations

### Improved
- **Code quality**: All bash scripts now pass shellcheck validation
- **Docker security**: All Dockerfiles now pass hadolint validation
- **YAML formatting**: All YAML files now pass yamllint validation
- **Test coverage**: Added negative tests for SQL injection, XSS, and other attack vectors
- **Test reliability**: Added load/stress tests with concurrent request handling

## [2.1.1] - 2025-01-15

### Fixed
- Dockerfile rewritten to use powerinit.sh script (reduced from 273 to 30 lines)
- Removed embedded script approach in Dockerfile
- Dynamic core management now properly working in CI/CD

### Removed
- Deprecated create_core.sh script (functionality moved to powerinit.sh)

## [2.1.0] - 2025-01-14

### Added
- `.env.example` template file for easy configuration
- **GitLab CI/CD pipeline** with testing (`.gitlab-ci.yml`)
  - 5 stages: Validate, Build, Test, Security, Cleanup
  - Parallel test execution (Unit, Integration, Moodle)
  - Security scanning for secrets and permissions
- GitHub Actions CI/CD workflow for automated testing (alternative)
- Structured logging with log rotation (10MB max, 3 files)
- **CI/CD Documentation**:
  - [GitLab Quick Start Guide](docs/GITLAB-QUICKSTART.md) (5-minute setup)
  - [Complete GitLab CI/CD Setup](docs/GITLAB-CI-CD-SETUP.md) (full guide)

### Changed
- **BREAKING**: `.env` file now located in root directory instead of `eledia-workplace/`
- **BREAKING**: Container naming scheme changed from `instance_service` to `instance-service` (e.g., `solr-solr` instead of `solr_solr`)
- Renamed `Dockerfile.init` to `Dockerfile` for standard naming convention
- Improved `.gitignore` to properly exclude secrets and environment files
- Fixed file permissions in init script: `chmod 655` → `chmod 755`
- Removed symlink logic from init container (simplified architecture)
- Updated docker-compose.yml to use `env_file` directive
- Improved health check for Solr container
- Updated all test scripts to reference new `.env` location
- Grafana port changed to standard 3000 (was 3005)

### Fixed
- Container name bug: Names now properly use INSTANCE_NAME variable
- Security: `.env` files now properly excluded from git tracking
- File permissions: Corrected directory permissions in init container
- Test scripts now compatible with new container naming scheme

### Security
- Enhanced `.gitignore` to prevent accidental secret commits
- Removed passwords from container environment variables
- Improved file permission handling

## [2.0.0] - 2024-12-27

### Added
- Initial stable release
- Solr 9.10.0 support
- Moodle 4.1-5.x compatibility
- Automated setup with password generation
- Multi-core support
- Prometheus + Grafana monitoring (optional)
- Comprehensive test suite
- Moodle document testing script
- SELinux compatibility (Fedora/RHEL)

### Features
- Three user roles: admin, moodle, support
- Double SHA256 password hashing
- Automatic password change detection
- Health checks for all services
- Volume persistence
- Docker Compose profiles for monitoring

[2.3.2]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v2.3.1...v2.3.2
[2.3.1]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v2.3.0...v2.3.1
[2.3.0]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v2.2.0...v2.3.0
[2.2.0]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v2.1.1...v2.2.0
[2.1.1]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v2.1.0...v2.1.1
[2.1.0]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/Codename-Beast/solr-moodle-docker/releases/tag/v2.0.0
