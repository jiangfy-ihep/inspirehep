# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Monorepo overview

INSPIRE HEP is a monorepo with four independently deployable services:

| Directory | Stack | Role |
|---|---|---|
| `backend/` | Python 3.11, Flask, Invenio | REST API + Celery workers |
| `ui/` | React 17, TypeScript, Redux | Public-facing web UI |
| `backoffice/` | Python 3.11, Django + DRF | Curator admin app |
| `workflows/` | Python 3.11, Apache Airflow | Data harvesting pipelines |

Infrastructure (always via Docker): **OpenSearch**, **PostgreSQL 14**, **Redis**, **RabbitMQ**, **MinIO** (S3-compatible).

---

## Commands

### Backend

```bash
cd backend

# Install dependencies
poetry env use $(uv python find 3.11)
poetry install

# Run all tests (smart incremental selection via testmon)
poetry run ./run-tests.sh

# Run all tests without testmon
poetry run ./run-tests.sh --all

# Run a single test file or test by name
poetry run py.test tests/unit/records/test_literature.py
poetry run py.test tests/integration/records -k test_create_record --no-cov

# Run only unit or integration suites
poetry run py.test tests/unit
poetry run py.test tests/integration --no-cov

# Lint (ruff)
poetry run ruff check inspirehep/
poetry run ruff format inspirehep/

# Start dev server (gunicorn + celery worker, auto-reloads)
./scripts/server
```

The test runner runs three suites in order: `tests/unit`, `tests/integration`, `tests/integration-async`. Testmon only re-runs tests affected by changed `.py` files; pass `--all` to override. The `tests/integration/orcid/helpers/` directory is excluded from test collection.

### UI

```bash
cd ui
nvm use 20.0.0
yarn install

yarn start                   # dev server on :3000 (proxies API to :8000)
yarn test                    # lint + unit tests + bundle size (CI-equivalent)
yarn test:unit               # jest in watch mode
yarn lint                    # ESLint only
NODE_OPTIONS=--openssl-legacy-provider yarn build   # production build
```

Node 20 is required — `NODE_OPTIONS=--openssl-legacy-provider` is needed for the build scripts.

### Backoffice

```bash
cd backoffice
poetry install

pytest .                          # all tests
pytest backoffice/authors/tests/  # specific app
pytest --reuse-db                 # skip DB recreation (default via addopts)
```

Uses `--ds=config.settings.test` and `--reuse-db` by default (pytest-django).

### Workflows

```bash
cd workflows
# Tests use pytest-vcr; cassettes are in tests/cassettes/
pytest tests/
pytest tests/test_hep_tasks.py -k test_arxiv
```

### Infrastructure

```bash
# Start all infra (local dev with overrides)
docker compose -f docker-compose.services.yml -f docker-compose.override.yml \
  up -d es mq db cache s3

# First-time DB setup only
docker exec inspirehep-db-1 psql -U postgres -c "CREATE DATABASE inspirehep;"
cd backend && direnv exec . poetry run inspirehep fixtures setup --with-fixtures

# Re-create S3 buckets (after re-enabling files)
cd backend && poetry run inspirehep files create-buckets

# Start dev session (tmux: backend + ui + shell windows)
./scripts/dev.sh
```

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

OpenSearch indices are defined in `inspirehep/search/mappings/`. Records are indexed asynchronously via Celery tasks (`inspirehep/indexer/tasks.py`). Search filters and facets are in `inspirehep/search/`. The app uses the `SEARCH_ELASTIC_HOSTS` config key (deprecated in favour of `SEARCH_HOSTS`) to locate OpenSearch.

### Serialization

Two serialization layers:
1. **Marshmallow schemas** (`inspirehep/records/marshmallow/`) — used for JSON API responses, one schema per record type.
2. **OpenSearch schemas** (`inspirehep/records/serializers/`) — used when indexing; `LiteratureFulltextElasticSearchSchema` adds fulltext fields when `FEATURE_FLAG_ENABLE_FULLTEXT=True`.

### Feature flags

Defined in `inspirehep/config.py`, all default to `False` locally:

| Flag | Effect |
|---|---|
| `FEATURE_FLAG_ENABLE_FILES` | Enable S3 file upload/download |
| `FEATURE_FLAG_ENABLE_FULLTEXT` | Index and search PDF fulltext |
| `FEATURE_FLAG_ENABLE_ORCID_PUSH` | Push records to ORCID |
| `FEATURE_FLAG_ENABLE_SEND_TO_BACKOFFICE` | Send workflows to backoffice |
| `FEATURE_FLAG_ENABLE_BAI_CREATION` | Auto-create BAI identifiers |

Override via `backend/.env` (loaded by direnv): `INVENIO_FEATURE_FLAG_ENABLE_FILES=True`.

### Celery

Celery app is in `inspirehep/celery.py`. Workers consume from queues: `celery` (default), `indexer_task`, `matcher`, `redirect_references`. The dev server script (`scripts/server`) starts the worker with `watchmedo auto-restart` for hot reloading.

---

## UI architecture

The UI is a React + Redux SPA using `craco` to extend Create React App. State management uses `immutable.js` for record data.

**Feature-based structure**: each record type (`literature/`, `authors/`, `conferences/`, etc.) is a self-contained module with its own components, containers, and reducers. Shared logic lives in `common/`.

**Redux store** (`ui/src/store.js`): custom middleware chain includes `queryParamsParser` (syncs URL search params to Redux), `statePersister` (persists `ui` and `user` slices to localStorage), `logoutUserOn401`, and `redirectToErrorPage`. The `user` and `ui` reducers are rehydrated from storage on startup.

**API communication**: all backend calls use `axios` via `axios-hooks`. The dev proxy (`ui/setupProxy.js`) forwards `/api/*` and `/literature/*` (etc.) to `http://localhost:8000`.

**Intranet access**: to expose the dev environment to other machines, three settings are required:
1. `HOST=0.0.0.0` is set in `scripts/dev.sh` so the CRA/craco dev server binds to all interfaces.
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

## Linting and code style

Root `ruff.toml` applies to the whole repo (Python 3.11 target). Key rules: `E`, `F`, `UP`, `B`, `SIM`, `I`, `TID`, `PT`. Line-length (`E501`) is ignored for `backend/**`. Migration files are excluded in backoffice.

Pre-commit hooks run ruff and other checks on commit — ensure `pre-commit install` has been run.
