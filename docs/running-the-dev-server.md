# Running the development services

Complete the [AlmaLinux 10 setup](local-setup-almalinux10.md) first
([中文](local-setup-almalinux10-cn.md)). These commands use native backend, UI,
and backoffice processes with Docker infrastructure. They do not start Airflow
or the complete asynchronous workflow stack. For the full Docker workflow,
follow the root README and the setup guide's topology notes.

Run each terminal's block starting at the repository root. The local `.env`
files must already contain the settings from the setup guide. Poetry manages
the Python environments and dependencies; no system Python changes are needed.

## Infrastructure terminal

```bash
docker compose -f docker-compose.yml -f docker-compose.override.yml \
  up -d db db-backoffice cache mq backoffice-mq es s3
docker compose -f docker-compose.yml -f docker-compose.override.yml ps
```

Use these same Compose files on every restart. The older `scripts/dev.sh`
selects a reduced topology that omits host RabbitMQ ports and the separate
backoffice infrastructure; use the explicit commands here instead.

## Backend terminal

```bash
cd backend
set -a
source ./.env
set +a
./scripts/server
```

The script uses Poetry to start Gunicorn on port 8000 and the backend Celery
worker, both with automatic reload. Keep the terminal open.

## UI terminal

```bash
nvm use 24.15.0
cd ui
INSPIRE_API_PROXY_TARGET=http://localhost:8000 yarn start
```

Vite listens on port 3000 and binds all interfaces. The override directs `/api`
requests to the native backend. Docker's default target remains
`http://hep-web:8000`. Do not set `NODE_OPTIONS=--openssl-legacy-provider` or
restore the removed CRA `setupProxy.js`.

## Backoffice terminal

```bash
cd backoffice
set -a
source ./.env
set +a
poetry run python manage.py runserver 0.0.0.0:8001
```

The guide's native environment disables loading the container `.envs` defaults
and uses the database on port 5434 and broker on port 5673. This starts Django;
it does not start the backoffice Celery worker or Airflow.

## Check the running services

```bash
curl --fail http://localhost:8000/api/literature/
curl --fail http://localhost:3000/api/literature/
curl --fail http://localhost:9200/_cluster/health
```

| Service | Local URL |
| --- | --- |
| UI / local login | `http://localhost:3000/user/login/local` |
| Backend API | `http://localhost:8000/api/literature/` |
| Backoffice admin | `http://localhost:8001/admin/` |
| MinIO console | `http://localhost:9001` |

The fixture UI login is `admin@inspirehep.net` / `123456`; backoffice is
`admin@admin.com` / `admin`. The local override uses MinIO credentials
`inspirehep` / `inspirehep`. Local UI login requires
`INVENIO_FEATURE_FLAG_ENABLE_LOCAL_LOGIN=True` in `backend/.env`.

For LAN access, use your actual hostname/IP, update the backend's server/schema
host settings, and request the administrator's firewall changes from the setup
guide. This page intentionally does not embed a particular host IP or assume
firewalld is installed.

## Stop and restart

Use `Ctrl+C` in each application terminal. To stop infrastructure while keeping
its containers:

```bash
docker compose -f docker-compose.yml -f docker-compose.override.yml stop
```

For persistence details, see the setup guide before using `down` or deleting
volumes. Do not run `fixtures setup`, index rebuilds, or `make run-e2e-test` as
daily startup checks; they reset data or recreate services.

You may put these same commands into separate tmux windows. Killing such a
tmux session stops its applications; detaching with `Ctrl+B`, then `d` leaves
them running.
