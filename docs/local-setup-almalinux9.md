# Local Development Setup — Alma Linux 9

This guide covers installing and running INSPIRE HEP locally on Alma Linux 9,
using `uv` for Python version management, `poetry` for backend dependencies,
and `tmux` to keep services running across terminal sessions.

---

## Table of Contents

- [Quick Start (post-setup)](#quick-start-post-setup)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
  - [1. System dependencies](#1-system-dependencies)
  - [2. Python 3.11 via uv](#2-python-311-via-uv)
  - [3. Node 20 via nvm](#3-node-20-via-nvm)
  - [4. Yarn](#4-yarn)
  - [5. Poetry](#5-poetry)
  - [6. pre-commit](#6-pre-commit)
  - [7. direnv](#7-direnv)
  - [8. Backend dependencies](#8-backend-dependencies)
  - [9. Environment variables](#9-environment-variables)
  - [10. Docker override file](#10-docker-override-file)
  - [11. Start infrastructure](#11-start-infrastructure)
  - [12. Initialize database and indices](#12-initialize-database-and-indices)
  - [13. UI dependencies](#13-ui-dependencies)
- [Usage](#usage)
  - [Starting the dev session](#starting-the-dev-session)
  - [Service URLs](#service-urls)
  - [Login credentials](#login-credentials)
  - [Generating an API token](#generating-an-api-token)
  - [Importing records](#importing-records)
  - [Running tests](#running-tests)
  - [Stopping services](#stopping-services)

---

## Quick Start (post-setup)

> If you have already completed the installation, use this section as your
> daily reference.

### Start everything

```bash
./scripts/dev.sh
```

This starts all Docker infrastructure (PostgreSQL, OpenSearch, Redis, RabbitMQ,
MinIO) and opens a tmux session with the backend and UI running. If the session
is already active, it reattaches to it.

### Service URLs

| Service | Local URL | Intranet URL |
|---|---|---|
| UI | http://localhost:3000 | http://\<HOST_IP\>:3000 |
| Backend API | http://localhost:8000 | http://\<HOST_IP\>:8000 |
| MinIO console | http://localhost:9001 | http://\<HOST_IP\>:9001 |
| OpenSearch | http://localhost:9200 | — |

The UI dev server binds to `0.0.0.0` so it is reachable from any machine on the same network.

### Admin credentials

| Account | Email | Password |
|---|---|---|
| Application admin | `admin@inspirehep.net` | `123456` |
| MinIO | `inspirehep` | `inspirehep` |

### Common admin tasks

**Generate an API token:**
```bash
cd backend && poetry run inspirehep tokens create -n mytoken -u admin@inspirehep.net
```

**Import records** — see all scenarios below.

### Importing records

The backend server must be running before importing. All commands run from the
`backend/` directory. A valid API token is required — generate one first:

```bash
poetry run inspirehep tokens create -n mytoken -u admin@inspirehep.net
```

Set it in `backend/inspirehep/config.py` as `AUTHENTICATION_TOKEN`, or pass it
via `--token <token>` on each command.

---

**All demo records** (quickest way to populate the local database):

```bash
poetry run inspirehep importer demo-records
```

---

**Single record from inspirehep.net by URL:**

```bash
poetry run inspirehep importer records \
  -u https://inspirehep.net/api/literature/20
```

**Multiple records from inspirehep.net in one command:**

```bash
poetry run inspirehep importer records \
  -u https://inspirehep.net/api/literature/20 \
  -u https://inspirehep.net/api/literature/1726642
```

Works for any record type — replace `literature` with `authors`, `conferences`,
`institutions`, `experiments`, `journals`, `seminars`, or `data`.

**Fetch and save locally** (writes JSON to `data/records/<type>/`):

```bash
poetry run inspirehep importer records \
  -u https://inspirehep.net/api/literature/20 \
  --save
```

---

**From a local JSON file:**

```bash
poetry run inspirehep importer records \
  -f data/records/literature/374836.json
```

**From multiple local JSON files at once:**

```bash
poetry run inspirehep importer records \
  -f data/records/literature/374836.json \
  -f data/records/authors/999108.json
```

---

**From a directory** (imports all `.json` files in that directory):

```bash
poetry run inspirehep importer records -d data/records/literature
poetry run inspirehep importer records -d data/records/authors
```

---

> The `-u`, `-f`, and `-d` flags can be combined and repeated freely in a
> single command to mix sources.

**Reset the database and indices from scratch:**
```bash
docker exec inspirehep-db-1 psql -U postgres -c "CREATE DATABASE inspirehep;" 2>/dev/null || true
cd backend && direnv exec . poetry run inspirehep fixtures setup --with-fixtures
```

### tmux reference

| Action | Command |
|---|---|
| Detach (keep running) | `Ctrl+B` then `d` |
| Reattach | `./scripts/dev.sh` |
| Switch windows | `Ctrl+B` then `1` / `2` / `3` |
| Kill session | `tmux kill-session -t inspirehep` |

### Stop everything

```bash
tmux kill-session -t inspirehep
docker compose -f docker-compose.services.yml -f docker-compose.override.yml down
```

---

## Prerequisites

The following must already be installed before starting:

- **Docker** (≥ 24) with the data root set to `/data/docker`
- **git**
- **nvm** — https://github.com/nvm-sh/nvm#installing-and-updating
- **curl**

---

## Installation

### 1. System dependencies

```bash
sudo dnf install -y \
  file-devel \
  postgresql-devel \
  openblas-devel \
  make
```

| Package | Required by |
|---|---|
| `file-devel` | `python-magic` (libmagic) |
| `postgresql-devel` | psycopg2 build headers |
| `openblas-devel` | numpy / scipy |
| `make` | project build scripts |

**Open firewall ports** so other machines on the intranet can reach the UI and
API (Alma Linux 9 uses `firewalld` by default):

```bash
sudo firewall-cmd --permanent --add-port=3000/tcp   # UI dev server
sudo firewall-cmd --permanent --add-port=8000/tcp   # Backend API
sudo firewall-cmd --reload
```

---

### 2. Python 3.11 via uv

The project requires Python `>=3.11,<3.12`. Use `uv` to install and manage it
without touching the system Python.

Install `uv` if not already present:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Then install Python 3.11:

```bash
uv python install 3.11
```

Verify:

```bash
uv run --python 3.11 python --version
# Python 3.11.x
```

---

### 3. Node 20 via nvm

The UI build scripts use `NODE_OPTIONS=--openssl-legacy-provider`, which
requires Node 20 (Node 22+ dropped support for this flag).

```bash
nvm install 20.0.0
nvm use 20.0.0
nvm alias default 20.0.0
```

---

### 4. Yarn

```bash
npm install -g yarn
```

---

### 5. Poetry

Install Poetry as an isolated tool via `uv`:

```bash
uv tool install poetry
```

Configure it to use Python 3.11 for this project:

```bash
cd backend
poetry env use $(uv python find 3.11)
```

---

### 6. pre-commit

```bash
uv tool install pre-commit
pre-commit install   # run from project root
```

---

### 7. direnv

Install the binary:

```bash
curl -sfL https://direnv.net/install.sh | bin_path=~/.local/bin bash
```

Hook it into bash (add to `~/.bashrc`):

```bash
echo 'eval "$(direnv hook bash)"' >> ~/.bashrc
source ~/.bashrc
```

---

### 8. Backend dependencies

From the `backend/` directory:

```bash
cd backend
poetry install
```

This installs ~300 packages including all git-sourced Invenio forks. Requires
network access to GitHub — enable a proxy if needed:

```bash
export http_proxy=http://<proxy-host>:<port>
export https_proxy=http://<proxy-host>:<port>
poetry install
```

---

### 9. Environment variables

Create `backend/.env` with local overrides:

```bash
# backend/.env
INVENIO_SEARCH_ELASTIC_HOSTS="['localhost:9200']"
INVENIO_S3_HOSTNAME=http://localhost:9000
INVENIO_S3_ACCESS_KEY=inspirehep
INVENIO_S3_SECRET_KEY=inspirehep
INVENIO_FEATURE_FLAG_ENABLE_FILES=True
INVENIO_SERVER_NAME=<HOST_IP>:8000
INVENIO_JSONSCHEMAS_HOST=<HOST_IP>:8000
```

Replace `<HOST_IP>` with your machine's intranet IP address (e.g. `192.168.1.100`). These two variables control the host embedded in generated record URLs and JSON schema `$id` fields. Without them, links returned by the API will reference `localhost`, which breaks on other machines.

Create `backend/.envrc` to tell direnv to load it:

```bash
echo "dotenv" > backend/.envrc
direnv allow backend/
```

From now on, entering the `backend/` directory in any terminal will
automatically load these variables.

> Both `.env` and `.envrc` are gitignored — safe to keep locally.

---

### 10. Docker override file

The default `docker-compose.services.yml` does not expose PostgreSQL to the
host and does not include MinIO. Create `docker-compose.override.yml` at the
project root:

```yaml
# docker-compose.override.yml
services:
  db:
    ports:
      - "5432:5432"
  s3:
    image: minio/minio
    ports:
      - "9000:9000"
      - "9001:9001"
    environment:
      - MINIO_ROOT_USER=inspirehep
      - MINIO_ROOT_PASSWORD=inspirehep
    command: server /data --console-address ":9001"
    volumes:
      - minio-data:/data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  minio-data:
```

> MinIO data is stored in a Docker named volume, consistent with how PostgreSQL
> and RabbitMQ store their data (under `/data/docker/volumes/`).

---

### 11. Start infrastructure

```bash
docker compose -f docker-compose.services.yml -f docker-compose.override.yml \
  up -d es mq db cache s3
```

Wait until all containers are healthy:

```bash
docker compose -f docker-compose.services.yml -f docker-compose.override.yml ps
```

Expected status: `healthy` for `db`, `cache`, `es`; `Up` for `mq`, `s3`.

---

### 12. Initialize database and indices

On **first run only**, the database must be pre-created before setup:

```bash
docker exec inspirehep-db-1 psql -U postgres -c "CREATE DATABASE inspirehep;"
```

Then run the full setup (initializes DB tables, OpenSearch indices, RabbitMQ
queues, MinIO buckets, and creates the admin user):

```bash
cd backend
direnv exec . poetry run inspirehep fixtures setup --with-fixtures
```

> On subsequent runs (e.g. after a reset), skip the `CREATE DATABASE` step —
> the setup command drops and recreates it automatically.

To create MinIO buckets independently (e.g. after re-enabling files):

```bash
cd backend
direnv exec . poetry run inspirehep files create-buckets
```

---

### 13. UI dependencies

```bash
cd ui
nvm use 20.0.0
yarn install
```

---

## Usage

### Starting the dev session

A tmux helper script starts all services and keeps them running even after
closing the terminal:

```bash
./scripts/dev.sh
```

This creates a tmux session named `inspirehep` with three windows:

| Window | Content |
|---|---|
| `backend` | Gunicorn (port 8000) + Celery worker with auto-reload |
| `ui` | React dev server (port 3000) with hot reload |
| `shell` | Free terminal at project root |

**tmux key reference:**

| Action | Keys |
|---|---|
| Switch windows | `Ctrl+B` then `1` / `2` / `3` |
| Detach (keep running) | `Ctrl+B` then `d` |
| Reattach later | `./scripts/dev.sh` or `tmux attach -t inspirehep` |
| Kill everything | `tmux kill-session -t inspirehep` |

---

### Service URLs

| Service | Local URL | Intranet URL |
|---|---|---|
| **UI** (React dev server) | http://localhost:3000 | http://\<HOST_IP\>:3000 |
| **Backend API** | http://localhost:8000 | http://\<HOST_IP\>:8000 |
| **OpenSearch** | http://localhost:9200 | — |
| **MinIO console** | http://localhost:9001 | http://\<HOST_IP\>:9001 |
| **RabbitMQ management** | http://localhost:15672 | — |

Replace `<HOST_IP>` with your machine's intranet IP (set in `backend/.env`). Ports 3000 and 8000 must be open in firewalld (see Step 1).

> Note: The README lists port 8080 for the full Docker stack. When running
> locally, the backend is on **8000** and the UI on **3000**.

---

### Login credentials

| Service | URL | Credentials |
|---|---|---|
| Inspirehep | http://localhost:3000/user/login/local | `admin@inspirehep.net` / `123456` |
| MinIO console | http://localhost:9001 | `inspirehep` / `inspirehep` |

---

### Generating an API token

```bash
cd backend
poetry run inspirehep tokens create -n <token-name> -u admin@inspirehep.net
```

Use the printed token in API requests:

```bash
curl -H "Authorization: Bearer <token>" http://localhost:8000/api/literature/
```

---

### Importing records

The backend server must be running before importing. Use `./scripts/dev.sh` or
start it manually.

**From the live inspirehep.net API:**

```bash
cd backend
poetry run inspirehep importer records \
  -u https://inspirehep.net/api/literature/20 \
  -u https://inspirehep.net/api/literature/1726642
```

Add `--save` to also write the fetched JSON to the local `data/` directory.

**From local JSON files:**

```bash
poetry run inspirehep importer records \
  -f data/records/literature/374836.json \
  -f data/records/authors/999108.json
```

**From a directory:**

```bash
poetry run inspirehep importer records -d data/records/literature
```

**All demo records at once:**

```bash
poetry run inspirehep importer demo-records
```

> A valid API token is required. Either set `AUTHENTICATION_TOKEN` in
> `backend/inspirehep/config.py` or pass `--token <token>`.

---

### Running tests

**Backend** (uses `testmon` to only run tests affected by changed files):

```bash
cd backend
poetry run ./run-tests.sh               # smart selection (default)
poetry run ./run-tests.sh --all         # run all tests
poetry run ./run-tests.sh -k test_name  # run specific test
poetry run ./run-tests.sh --pdb         # drop into debugger on failure
```

Run `py.test` directly with testmon:

```bash
poetry run py.test tests/integration/records --testmon --no-cov
```

**UI** (Jest):

```bash
cd ui
yarn test         # lint + unit tests + bundle size check (same as CI)
yarn test:unit    # unit tests in watch mode
```

**End-to-end** (Cypress):

```bash
# Full run (rebuilds all containers — destructive)
make run-e2e-test

# Against local dev server
cd e2e
yarn test:dev

# Single spec
docker compose run --rm cypress cypress run \
  --browser firefox --headless \
  --env inspirehep_url=http://host.docker.internal:8080 \
  --spec cypress/e2e/jobs.test.js
```

---

### Stopping services

**Detach from tmux** (services keep running):

```
Ctrl+B then d
```

**Stop everything:**

```bash
tmux kill-session -t inspirehep
docker compose -f docker-compose.services.yml -f docker-compose.override.yml down
```
