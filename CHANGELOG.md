# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
