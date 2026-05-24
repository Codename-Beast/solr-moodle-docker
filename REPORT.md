# Solr Multi-Tenant — Implementation & Test Report

**Date:** 2026-05-10  
**Version:** v3.0.0 (feature/multi-tenant)  
**Author:** BSC Bernd Schreistetter, Eledia.de

---

## What Is Implemented

### Multi-Tenant Architecture

A single Solr 9.x instance serves multiple independent Moodle installations. Each Moodle
instance (tenant) receives:

- Dedicated Solr user with a 32-character random password
- Dedicated Solr cores (one per Moodle instance, e.g. `moodle_prod_a`, `moodle_test_a`)
- Write and read access to its own cores via Solr's `RuleBasedAuthorizationPlugin`

Tenant isolation at the URL routing level is handled by a Caddy reverse proxy
(separate configuration, not in this repo).

### Security Model

**Roles (standalone mode):**

| User | Role | Access |
|------|------|--------|
| `admin` | `admin` | Full Solr admin (all APIs) |
| `support` | `support` | Read-only across all cores, no writes |
| `solr_<tenant>` | `tenant` | Read + write to all cores (Caddy restricts per-URL) |

**Permissions in `security.json`:**

| Permission | Role | Paths |
|-----------|------|-------|
| `health` | `null` (anonymous) | `/admin/ping` |
| `security-edit` | `admin` | security API |
| `security-read` | `admin`, `support` | security API read |
| `metrics-read` | `admin`, `support` | `/admin/metrics` |
| `core-admin-read` | `admin`, `support` | core status API |
| `core-admin-edit` | `admin` | core create/delete API |
| `collection-admin-read` | `admin`, `support` | collections read |
| `collection-admin-edit` | `admin` | collections write |
| `tenant-read` | `admin`, `support`, `tenant` | `/select`, `/admin/ping`, `/schema`, `/replication` |
| `tenant-write` | `admin`, `tenant` | `/update`, `/update/extract` |

**Why `collection` field is not used in standalone mode:**  
Solr 9.x's `RuleBasedAuthorizationPlugin` only evaluates the `collection` field in
SolrCloud mode (where the collection name is part of the request context). In standalone
mode, the core name in the URL path is not exposed to the auth plugin, so all custom
permissions without `collection` field are evaluated by path only. This means
`tenant-read`/`tenant-write` grant access to all cores for all tenant users. URL-level
isolation (which Moodle accesses which core) is enforced by the Caddy proxy, not Solr.

In **SolrCloud mode** (`SOLR_MODE=solrcloud`), per-collection permissions ARE created with
the `collection` field and Solr enforces true server-side isolation.

### Key Files

#### `docker-compose.yml`
- `solr-init` service runs `powerinit.sh` on every container start
- `solr` service starts only after `solr-init` completes successfully
- `tenants.env` is bind-mounted into both services
- Monitoring stack completely removed

#### `init/powerinit.sh`
Runs inside the `solr-init` container on every start. Rebuilds `security.json` completely
from `.env` + `tenants.env`. Steps:
1. Validate environment variables
2. Load `tenants.env` into associative arrays
3. Create `moodle-tenant` configset (idempotent)
4. Generate `security.json`: admin + support credentials + all active tenants
5. Pre-create core directories for all active tenants (standalone only)
6. Fix file permissions
7. Validate the generated JSON

#### `init/security.json.template`
Static skeleton with admin and support placeholders. `powerinit.sh` replaces placeholders
and appends tenant credentials + permissions at runtime.

#### `scripts/solr-tenant.sh`
CLI for tenant management inside the container. Subcommands:

| Command | Description |
|---------|-------------|
| `create <name> --cores <c1>[,c2]` | Create tenant with cores, print credentials |
| `delete <name> [--force]` | Deactivate tenant (data preserved, login blocked) |
| `enable <name>` | Re-activate with new password |
| `passwd <name>` | Reset password, print new one |
| `list` | Table of all tenants with status |
| `info <name>` | Details for one tenant |
| `core-add <name> --core <core>` | Add core to existing tenant |
| `core-remove <name> --core <core>` | Remove core from tenant |
| `apply` | Re-apply all tenants from tenants.env idempotently |
| `export` | YAML output for Ansible host_vars |
| `caddy-config --domain <d>` | Generate Caddy per-tenant route config |

#### `scripts/solr-backup.sh`
Reads all core names from `tenants.env` and triggers a Solr Replication API backup
for each core into `$BACKUP_DIR/<core>_<timestamp>/`.

#### `scripts/run-tests.sh`
Full test suite with 8 test categories (unit, integration, security, negative, performance,
moodle-documents, tenant, solrcloud). Supports `--tenant` and `--cloud` flags.

#### `scripts/test-moodle-documents.sh`
Tests Moodle-realistic document indexing including:
- Forum posts, courses, wikis, glossaries, book chapters, assignments
- Query tests (phrase search, wildcard, faceting, highlighting, sorting)
- Tika file indexing via `/update/extract` with a real PDF containing the unique marker
 `ELEDIA_TIKA_TEST_MARKER`

#### `setup.sh`
Interactive first-install script: generates passwords, creates `.env` and `tenants.env`,
configures logrotate, builds init image, starts Solr, waits for healthy state.

#### `tenants.env` (not in git)
Single source of truth for all tenant configurations. Format:
```
TENANT_schule_a_CORES=moodle_prod_a,moodle_test_a
TENANT_schule_a_USER=solr_schule_a
TENANT_schule_a_PASS=<32-char-random>
TENANT_schule_a_ACTIVE=true
```

#### `config/managed-schema`
Moodle's global search schema. Key fields: `id`, `title`, `content`, `areaid`,
`contextid`, `courseid`, `itemid`, `modified`, `type`, `owneruserid`.
Includes `ignored` catchall `dynamicField` for unknown Moodle fields.

#### `config/solrconfig.xml`
- `SOLR_MODULES=extraction` enables Tika (`/update/extract`)
- `managedSchemaFactory` allows Moodle to update the schema at runtime via API
- Auto-soft-commit every 2 seconds for near-real-time search

---

## What Is Tested (Local Test Suite)

### Test Run Results (2026-05-10, clean run)

```
Total Tests:  73
Passed:       73
Failed:       0
Success Rate: 100%
```

### Unit Tests
- docker-compose.yml syntax ✓
- Required files present ✓
- Script permissions ✓
- `.env.example` contains required variables ✓
- Docker images available ✓
- `.env` not tracked in git ✓

### Integration Tests
- Container startup and health ✓
- Solr core creation via `solr-tenant.sh` ✓
- `security.json` created with 600 permissions ✓
- Admin authentication (HTTP 200) ✓
- Anonymous access blocked (HTTP 401) ✓
- Core status API returns correct core name ✓
- `security.json` regenerated on password change ✓

### Security Tests
- Solr bound to `127.0.0.1` only ✓
- Runs as non-root user (UID 8983) ✓
- Privileged mode disabled ✓
- `security.json` permissions 600 ✓
- `.env` in `.gitignore` ✓
- Default passwords not in use ✓
- `tenants.env` accessible in container ✓

### Negative Tests
- Invalid credentials rejected (401) ✓
- SQL injection in query handled safely (200/400/404) ✓
- XSS in query not reflected ✓
- Extremely long query handled (414) ✓
- Invalid core name rejected (404) ✓
- Empty query handled (200/400) ✓

### Performance Tests
- Admin API response time: **14ms** ✓
- Container memory usage: **~687 MiB** ✓
- Healthcheck endpoint responsive ✓
- 10 concurrent requests in **17ms** ✓
- 20 sequential queries, average: **6–7ms** ✓

### Moodle Document Tests (23 tests)
- Connectivity and authentication ✓
- 7 realistic Moodle documents indexed ✓
- Simple text search (`q=Solr`) — 7 results ✓
- Field-specific search (`title:performance`) — 1 result ✓
- Filter query (`fq=courseid:5`) — 3 results ✓
- Area filter (forum posts OR book chapters) ✓
- Phrase search (`"Apache Solr"`) ✓
- Wildcard search (`optimi*`) ✓
- Highlighting (`hl=true`) ✓
- Faceting by `areaid` (12 facet values) ✓
- Sorting by modified date ✓
- Index document count (7 documents) ✓
- **Tika PDF extraction** (`/update/extract?extractOnly=true`) — marker found ✓
- **Tika PDF indexing** (`/update/extract?commit=true`) — HTTP 200 ✓
- **PDF content searchable** — `ELEDIA_TIKA_TEST_MARKER` found ✓
- **PDF text search** (`moodle solr tika`) — results found ✓
- Cleanup (index empty after test) ✓

### Multi-Tenant Tests
- Create tenant `schule_a` (core: `moodle_prod_a`) ✓
- User `solr_schule_a` present in `security.json` ✓
- Tenant access to own core (`/select` → 200) ✓
- **Admin API blocked for tenant** (`/admin/cores` → 403) ✓
- Create tenant `schule_b` (core: `moodle_prod_b`) ✓
- **Auth isolation** (wrong password → 401) ✓
- **Support can read** (`moodle_prod_a/select` → 200) ✓
- **Support CANNOT write** (`moodle_prod_a/update` → 403) ✓
- `core-add`: add `moodle_test_a` to `schule_a` ✓
- Access to new core (`moodle_test_a/select` → 200) ✓
- Delete tenant → login blocked (401) ✓
- Enable tenant → new password works (200) ✓
- `apply` is idempotent (no errors) ✓
- **Restart persistence** (tenants survive `docker compose restart`) ✓

### Cleanup Tests
- Container restart without data loss ✓
- Graceful shutdown ✓
- Named volume persists after shutdown ✓

---

## Bugs Fixed During This Session

| Bug | Root Cause | Fix |
|-----|-----------|-----|
| Support gets HTTP 200 on `/update` | `collection` field in permissions skipped in standalone; default = ALLOW | Removed per-tenant per-collection permissions; added shared `tenant-read`/`tenant-write` without `collection` field |
| `all` predefined permission blocks non-admin users | `all` (path=`*`) was 2nd in array; first-match denied all non-admin before tenant perms | Removed `all`; replaced with explicit `security-edit`, `core-admin-edit`, etc. |
| `_write_user_role` assigns array instead of string | `jq` template `[$r]` creates JSON array; Security API role matching requires string | Changed to `$r` (string) |
| `sed -i` in `_set_tenant_field` permission denied | `sed -i` creates temp file in `/opt/solr/` which is read-only in container | Replaced with `mktemp` + `cat >` pattern |
| `enable` test extracts wrong password | `awk '{print $2}'` prints `Password:` label, not value | Changed to `awk '{print $3}'` |
| `cmd_apply` uses hardcoded `tenant-<name>` role | Standalone should use flat `"tenant"` role | Changed to `_get_tenant_role` |
| `cmd_core_add` uses hardcoded role | Same as above | Changed to `_get_tenant_role` |
| Tika PDF indexing returns 400 | Missing required schema fields (`itemid`, `courseid`, `owneruserid`, `modified`, `type`) | Added `literal.*` query parameters for all required fields |
| Port hardcoded as 8983 in tests | Tests failed on local dev (port 8985) | Replaced all occurrences with `${SOLR_PORT:-8983}` |
| Monitoring tests present in run-tests.sh | Not removed in previous session | Removed `monitoring_tests()` function entirely |
| Negative tests fail with 404 | SOLR_CORE_NAME defaults to `moodle_core` which doesn't exist | Added 404 as acceptable response alongside 200/400 |

---

## What Could Still Be Tested

### Integration With Real Moodle
- Connect Moodle 4.5 admin panel to test Solr (Global Search settings)
- Verify "Check connection" shows green for all endpoints
- Run `php admin/tool/globalseach/cli/indexer.php` and verify content is searchable in Moodle
- Test file indexing from Moodle (attach PDF/DOCX to a resource, verify full-text search finds it)

### SolrCloud Mode
- Start with `SOLR_MODE=solrcloud` and verify:
 - Embedded ZooKeeper starts correctly
 - Collections API creates collections
 - `collection` field in permissions enforces true per-collection isolation (403 for cross-tenant access)
 - Restart persistence via ZooKeeper (credentials survive restart without re-running init)

### Caddy Proxy Integration
- Run `solr-tenant.sh caddy-config --domain solr.example.com`
- Verify generated Caddyfile routes `solr.example.com/<tenant>/*` → `localhost:8983/solr/<core>/*`
- Verify that tenant A cannot reach tenant B's core via the proxy
- Verify support user can reach all cores via direct URL

### Ansible Role (`feature/1.9.5`)
- Run `ansible-playbook install_solr.yml --tags solr_tenants` against a staging server
- Verify `solr_tenants:` variable creates tenants idempotently
- Verify `state: absent` deactivates tenants correctly
- Verify `solr_sync_tenant_credentials: true` writes to host_vars

### Backup & Restore
- Run `docker exec solr /opt/solr/scripts/solr-backup.sh`
- Verify backup directories created for all tenant cores
- Test restore: delete a core, restore from backup, verify data is present

### Schema API Updates
- Index a document, then add a new field via Moodle's Schema API
- Verify the new field is stored and searchable
- Verify the `ignored` catchall `dynamicField` prevents unknown-field errors

### High-Availability / Stress
- Run 100+ concurrent Moodle search requests and measure Solr's response times
- Test with large document sets (10,000+ documents per core)
- Test automatic soft-commit timing (verify documents appear within 2 seconds)

### Password Rotation
- Run `solr-tenant.sh passwd schule_a`
- Verify Moodle loses connection (old password no longer works)
- Update Moodle config with new password, verify connection is restored

### Container Restart After Security Changes
- Add a new tenant via `solr-tenant.sh create`
- Run `docker compose restart` (full restart including solr-init)
- Verify powerinit.sh regenerates security.json and all tenants are present
- Verify the new tenant's password from `tenants.env` is still valid

---

## Known Limitations

1. **No URL isolation in standalone mode without Caddy**: All tenants with role `"tenant"`
  can technically reach any core at the Solr level. The Caddy reverse proxy must be
  configured to enforce per-tenant URL routing. Run `solr-tenant.sh caddy-config` to
  generate the Caddyfile.

2. **SolrCloud with single node embedded ZK**: While `SOLR_MODE=solrcloud` enables true
  collection-level isolation, the embedded ZooKeeper is not suitable for production HA.
  For production SolrCloud, use an external ZooKeeper ensemble.

3. **No Moodle-to-Solr SSL inside Docker**: Moodle connects to Solr via the Caddy proxy
  which terminates SSL. Internal Docker network traffic (Caddy → Solr) is plaintext. This
  is acceptable in a single-host Docker setup with localhost binding.

4. **Tika runs inside Solr**: The Solr `extraction` module bundles Apache Tika. There is
  no separate Tika container. This means very large PDF processing happens inside the Solr
  JVM, which can increase memory pressure. The `SOLR_HEAP` setting should account for this.


## solr-helper-pro local UI notes
- `scripts/solr-helper-pro.py` is treated as local-only operator tooling in this workspace.
- Current UI behavior: create button in list header, selection-driven right panel (host+container info + live logs), tenant-capable column in server list, and detail screen with inline config/user/log operations plus Solr runtime/schema summary.
- Theme direction: dark black/orange with stronger borders and accents.
