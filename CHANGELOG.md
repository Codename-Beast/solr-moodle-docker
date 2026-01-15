# Changelog
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
- **Dockerfile DL3059 warning**: Consolidated multiple RUN instructions to reduce image layers

### Changed
- **GitHub Actions workflow**:
  - Added  code quality checks (shellcheck, hadolint, yamllint)
  - Added Trivy security vulnerability scanning for both init and Solr images
  - Split testing into lint, security-scan, and test stages
  - Added matrix testing for multiple core configurations
  - Added automated password generation testing
  - Added dynamic core management testing
- **GitLab CI/CD pipeline**:
  - Added `needs` dependencies for proper job ordering
  - Added fallback package installation for different Ubuntu versions
  - Added docker daemon readiness checks
- **Dockerfile**: Consolidating RUN commands

### Added
- **CI/CD configuration files**:
  - `.shellcheckrc`: Shellcheck configuration to disable false positives
  - `.hadolint.yaml`: Hadolint configuration for Dockerfile linting
  - `.yamllint`: Yamllint configuration for YAML validation

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

[2.1.0]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/Codename-Beast/solr-moodle-docker/releases/tag/v2.0.0
