# Agent Instructions

These instructions apply throughout this repository. Follow more specific
directory instructions and explicit user instructions where they differ.
Always respond in English.

Read `README.md`, `CONTRIBUTING.md`, and the affected service's configuration
before making changes. Package scripts, test scripts, and CI workflows are the
source of truth when documentation differs from executable configuration.

---

## Monorepo overview

INSPIRE HEP contains the following applications:

| Directory | Stack | Role |
|---|---|---|
| `backend/` | Python 3.11, Flask, Invenio | REST API + Celery workers |
| `ui/` | React 19, TypeScript, Redux 5, Vite | Public-facing web UI |
| `backoffice/` | Python 3.11, Django + DRF | Curator admin app |
| `workflows/` | Python 3.11, Apache Airflow | Data harvesting pipelines |
| `record-editor/` | Angular 4, TypeScript | Legacy record editing application |
| `renderer/` | Node.js | Rendering service |
| `e2e/` | Cypress | End-to-end tests |

Infrastructure (always via Docker): **OpenSearch**, **PostgreSQL 14**, **Redis**, **RabbitMQ**, **MinIO** (S3-compatible).

---

## Commands

Prefer the documented Docker Compose workflow: `make run`,
`make run-inspirehep`, or `make run-backoffice`. The full stack needs about
18 GB RAM; inspect the README prerequisites before starting it.

Reuse existing project environments. Backend and backoffice use Poetry and
Python 3.11; JavaScript applications use Yarn. Honor each service's version
constraints and lockfile. Do not replace Poetry with uv, use `pip install`, or
regenerate lockfiles without a dependency change. uv may manage the Python
interpreter separately, as described in the AlmaLinux setup guides.

### Backend

```bash
cd backend

# Install dependencies
poetry install

# Run tests with incremental integration-test selection via testmon
poetry run ./run-tests.sh

# Run all tests without testmon selection (collection remains enabled)
poetry run ./run-tests.sh --all

# Run a single test file or test by name
poetry run py.test tests/unit/records/test_literature.py
poetry run py.test tests/integration/records -k test_create_record --no-cov

# Run only unit or integration suites
poetry run py.test tests/unit
poetry run py.test tests/integration --no-cov

# Start dev server (gunicorn + celery worker, auto-reloads)
./scripts/server
```

The test runner runs three suites in order: `tests/unit`, `tests/integration`, `tests/integration-async`. Testmon only re-runs tests affected by changed `.py` files; pass `--all` to override. The `tests/integration/orcid/helpers/` directory is excluded from test collection.

### UI

```bash
cd ui
nvm use 24.15.0
yarn install

INSPIRE_API_PROXY_TARGET=http://localhost:8000 yarn start
yarn test                    # lint + types + coverage + bundle size
yarn test:unit               # Vitest, one run
yarn test:type               # TypeScript checks
yarn lint                    # ESLint only
yarn build                   # Vite production build
```

Use Node 24.15.0, matching the UI Dockerfiles. Vite does not need the old
`--openssl-legacy-provider` option. `ui/vite.config.mts` serves port 3000 on
all interfaces. Its `/api` proxy defaults to `http://hep-web:8000` for Docker;
the local launcher sets `INSPIRE_API_PROXY_TARGET=http://localhost:8000`.

### Backoffice

```bash
cd backoffice
poetry install

poetry run pytest .                          # all tests
poetry run pytest backoffice/authors/tests/  # specific app
```

Uses `--ds=config.settings.test` and `--reuse-db` by default (pytest-django).
Alternatively, from the repository root:

```bash
docker compose exec -T backoffice-worker pytest .
```

### Workflows

```bash
# Tests use pytest-vcr; cassettes are in tests/cassettes/
docker compose exec -T airflow-worker pytest tests
docker compose exec -T airflow-worker pytest tests/test_hep_tasks.py -k test_arxiv
```

### Infrastructure

```bash
# Start all infra (local dev with overrides)
docker compose -f docker-compose.services.yml -f docker-compose.override.yml \
  up -d es mq db cache s3

# First-time DB setup only
docker exec inspirehep-db-1 psql -U postgres -c "CREATE DATABASE inspirehep;"
(cd backend && direnv exec . poetry run inspirehep fixtures setup --with-fixtures)

# Re-create S3 buckets (after re-enabling files)
(cd backend && poetry run inspirehep files create-buckets)

# Start dev session from the repository root
# tmux: backend + UI + backoffice + shell windows
./scripts/dev.sh
```

### Syncing with upstream

`master` tracks `upstream/master` (official repository). Local adaptations live
on `dev`, which tracks `origin/dev` in the personal fork. The former
`origin/local` branch has been renamed to `origin/dev`.

| Remote | URL | Role |
|---|---|---|
| `upstream` | `https://github.com/inspirehep/inspirehep` | official repository; fetch only, push URL disabled |
| `origin` | `git@github.com:jiangfy-ihep/inspirehep.git` | personal fork; default push destination |

```bash
# Start with a clean working tree.
git fetch upstream
git switch master
git merge --ff-only upstream/master
git switch dev
git pull --ff-only origin dev
git merge upstream/master
# Resolve conflicts and run the affected services' checks before pushing.
git push origin dev
```

Merge upstream updates into published `dev`; do not rewrite shared history or
force-push it. Preserve the Vite proxy override when resolving UI conflicts;
upstream removed `ui/src/setupProxy.js` during its migration from CRA to Vite.
Do not assume additional remotes or hard-code proxy settings.

Create focused feature, fix, refactor, and chore branches from `master` unless
the user specifies another base. Use kebab-case names with `feat/`, `fix/`,
`refactor/`, or `chore/` prefixes. Commit subjects use
`type: imperative summary`, at most 72 characters, without `Co-authored-by`
trailers. Preserve unrelated user changes. For upstream contributions, follow
issue assignment and PR requirements in `CONTRIBUTING.md`; PR titles use
`<area>: <what changed>`.

---

## Backend architecture

### Invenio framework

The backend is built on [Invenio](https://invenio-software.org/), a digital library framework. Key concepts:

- **Entry points** (in `pyproject.toml` `[tool.poetry.plugins.*]`) wire together blueprints, extensions, models, search mappings, and Celery tasks — not explicit imports. Adding a new blueprint requires registering it under `invenio_base.api_blueprints`.
- **App factory** (`inspirehep/factory.py`): `create_app()` builds a Flask app with a `DispatcherMiddleware` that routes `/api/*` to a separate REST API app. Config is loaded from `inspirehep/config.py` and overridden by `INVENIO_*` environment variables.
- **Config override**: any key in `config.py` can be overridden at runtime by setting `INVENIO_<KEY>=value` in the environment.

### Record system

All record types live in `backend/inspirehep/records/api/` and inherit from `InspireRecord` (base class). Record types map to PID types:

| Record class | PID type | Index |
|---|---|---|
| `LiteratureRecord` | `lit` | `records-hep` |
| `AuthorsRecord` | `aut` | `records-authors` |
| `ConferencesRecord` | `con` | `records-conferences` |
| `InstitutionsRecord` | `ins` | `records-institutions` |
| `ExperimentsRecord` | `exp` | `records-experiments` |
| `JournalsRecord` | `jou` | `records-journals` |
| `JobsRecord` | `job` | `records-jobs` |
| `SeminarsRecord` | `sem` | `records-seminars` |
| `DataRecord` | `dat` | `records-data` |

`InspireRecord` validates against JSON schemas (from `inspire-schemas`), manages persistent identifiers via Invenio PIDStore, and handles nested record relationships via mixins (`CitationMixin`, `InstitutionPapersMixin`, etc.).

### Search and indexing

OpenSearch mappings are defined in `backend/inspirehep/search/mappings/`.
Records are indexed asynchronously via Celery tasks in
`backend/inspirehep/indexer/tasks.py`. Search filters and facets are in
`backend/inspirehep/search/`; inspect the service configuration and Compose
environment before changing OpenSearch connection settings.

### Serialization

Two serialization layers:
1. **Marshmallow schemas** (`inspirehep/records/marshmallow/`) — used for JSON API responses, one schema per record type.
2. **OpenSearch schemas** (`inspirehep/records/serializers/`) — used when indexing; `LiteratureFulltextElasticSearchSchema` adds fulltext fields when `FEATURE_FLAG_ENABLE_FULLTEXT=True`.

### Feature flags

Defined in `backend/inspirehep/config.py`; the flags below default to `False`:

| Flag | Effect |
|---|---|
| `FEATURE_FLAG_ENABLE_FILES` | Enable S3 file upload/download |
| `FEATURE_FLAG_ENABLE_FULLTEXT` | Index and search PDF fulltext |
| `FEATURE_FLAG_ENABLE_ORCID_PUSH` | Push records to ORCID |
| `FEATURE_FLAG_ENABLE_LOCAL_LOGIN` | Enable local development login |
| `FEATURE_FLAG_ENABLE_BAI_CREATION` | Auto-create BAI identifiers |

Override via the project's local environment setup, for example
`INVENIO_FEATURE_FLAG_ENABLE_FILES=True`. Local login also requires
`INVENIO_FEATURE_FLAG_ENABLE_LOCAL_LOGIN=True`. Never commit environment secrets.

### Celery

Celery app is in `inspirehep/celery.py`. Workers consume from queues: `celery` (default), `indexer_task`, `matcher`, `redirect_references`. The dev server script (`scripts/server`) starts the worker with `watchmedo auto-restart` for hot reloading.

---

## UI architecture

The UI is a React 19 + Redux 5 SPA built with Vite and tested with Vitest.
State management uses `immutable.js` for record data.
The newer record editor lives in `ui/src/editor/`; `record-editor/` contains
the legacy Angular application with its own scripts and dependencies.

**Feature-based structure**: each record type (`literature/`, `authors/`, `conferences/`, etc.) is a self-contained module with its own components, containers, and reducers. Shared logic lives in `common/`.

**Redux store** (`ui/src/store.js`): custom middleware chain includes `queryParamsParser` (syncs URL search params to Redux), `statePersister` (persists `ui` and `user` slices to localStorage), `logoutUserOn401`, and `redirectToErrorPage`. The `user` and `ui` reducers are rehydrated from storage on startup.

**API communication**: backend requests use the shared Axios client and
`axios-hooks`. The Vite dev proxy forwards `/api` requests to the target
described in the UI commands above.

**Intranet access**: to expose the dev environment to other machines, three settings are required:
1. `server.host: true` in `ui/vite.config.mts` binds Vite to all interfaces.
2. `INVENIO_SERVER_NAME` and `INVENIO_JSONSCHEMAS_HOST` in `backend/.env` must be set to the host machine's IP (e.g. `192.168.1.100:8000`) — without these, generated links reference `localhost` and break on remote clients.
3. Firewall: `sudo firewall-cmd --permanent --add-port=3000/tcp --add-port=8000/tcp && sudo firewall-cmd --reload`.

---

## Workflows architecture

Airflow DAGs in `workflows/dags/` are organised by data source:

- `literature/` — harvesting from arXiv, Elsevier, IEEE, CDS; the main `hep_create_dag.py` orchestrates the full literature ingestion pipeline (harvest → parse → match → merge → push to backoffice/inspirehep)
- `author/` — author record creation workflow
- `data/` — HEPData harvesting
- `cds/` — CERN Document Server harvesting
- `service/` — maintenance DAGs (log cleanup)

DAG tasks call the INSPIRE REST API and backoffice API directly. HTTP calls in tests are mocked with `pytest-vcr` cassettes (`tests/cassettes/`).

---

## Backoffice architecture

Django app managing curation workflows. Two main Django apps:

- `backoffice/authors/` — author merge/disambiguation decisions
- `backoffice/hep/` — literature approval/rejection workflows

Workflows arrive from the Airflow `workflows/` service via REST API calls. The backoffice stores workflow state in PostgreSQL and exposes a DRF API consumed by both the UI (`ui/src/holdingpen/`, `ui/src/backoffice/`) and Airflow tasks.

---

## Bulk data import

The companion project `../curation_stats/` supplies InspireHEP API JSON snapshots
for bulk import into the local instance. It is a separate checkout and may not
be present; check that the symlink targets exist before using these commands.

```bash
# Dry-run first — counts records by type
./import_records.sh --dry-run

# Full import (requires backend running)
./import_records.sh

# Keep converted files for inspection
./import_records.sh --keep-tmp
```

`import_records.sh` and `IMPORT.md` are softlinks to `../curation_stats/`. The script:

1. Recursively scans `../curation_stats/records/`, excluding `*.pre.json` (pre-curation snapshots)
2. Extracts `metadata` to top level (API wrapper → raw record format)
3. Infers `_collections` from `$schema` if missing
4. Deduplicates by `control_number`
5. Calls `inspirehep importer records -d <flat-tmp-dir>`

## Documentation

- `docs/local-setup-almalinux9.md` — full setup guide for Alma Linux 9
- `docs/local-setup-almalinux9-cn.md` — Chinese translation of the setup guide
- `IMPORT.md` — bulk import usage guide (softlink to `../curation_stats/IMPORT.md`)

## Linting and code style

Root `ruff.toml` applies to the whole repo (Python 3.11 target). Key rules: `E`, `F`, `UP`, `B`, `SIM`, `I`, `TID`, `PT`. Line-length (`E501`) is ignored for `backend/**`. Migration files are excluded in backoffice.

Keep changes focused, follow service formatters, and avoid mass formatting or
unrelated dependency updates. Use type annotations for new Python APIs and
existing TypeScript patterns. Document public APIs, handle external failures
explicitly, and reserve assertions for internal invariants. Add meaningful
regression tests for behavior changes. Coordinate API, schema, indexing, and
workflow changes across service boundaries when necessary. Use portable paths
and preserve repository line endings.

Run `pre-commit run --files <changed-files>` from the root for Python changes;
the root hooks apply to `backend/`, `backoffice/`, and `workflows/`.
Inspect other JavaScript services' `package.json` scripts before choosing checks.
Run relevant suites before completing implementation work and verify the
affected workflow end to end when feasible. `make run-e2e-test` recreates
development containers, so account for existing services before running it.
For documentation-only changes, review the content and run `git diff --check`.
Report exactly what ran, failures, and unavailable checks; never claim
unverified success. Never commit credentials or secrets from local environments
or recorded test cassettes.
