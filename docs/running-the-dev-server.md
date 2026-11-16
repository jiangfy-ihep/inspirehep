# Running the development services

> **Current workspace: testing stopped on 2026-11-16.** Rootless Docker failed
> during network setup because `/dev/net/tun` is absent; a separate nested
> overlay mount probe also failed. No local INSPIRE services were started.
> The user will try another machine. These commands remain a reference for a
> future validated setup, not an instruction to resume testing on this host.
> See the [actual test results](local-setup-almalinux10.md#9-recorded-tests-and-blockers-2026-11-16).

Complete the [AlmaLinux 10 setup](local-setup-almalinux10.md) first
([中文](local-setup-almalinux10-cn.md)). These commands use native backend, UI,
and backoffice processes with Docker infrastructure. They do not start Airflow
or the complete asynchronous workflow stack. For the full Docker workflow,
follow the root README and the setup guide's topology notes.

Run each terminal's block starting at the repository root. The local `.env`
files must already contain the settings from the setup guide. Poetry manages
the Python environments and dependencies; no system Python changes are needed.

## Rootless Docker prerequisite: no systemd in this workspace

This is an AlmaLinux 10.2 container on Kubernetes. Systemd is installed but PID 1
is `bash`. The user has completed the setup guide's one-time sudo preparation
for slirp4netns and private runtime/data directories (verified 2026-11-16).
Rootless Docker startup itself needs no sudo, but the actual attempt failed.
Only if runtime testing is explicitly resumed, first follow the setup guide's
[daemon and socket checks](local-setup-almalinux10.md#start-rootless-docker-without-sudo-or-systemd)
to avoid duplicates. If stopped, run this as the development account in a
dedicated terminal or tmux session:

```bash
export XDG_RUNTIME_DIR=/run/user/23739
dockerd-rootless.sh --data-root=/var/tmp/jiangfayu-docker-rootless
```

Keep the daemon session running. Do not use `sudo dockerd`,
`newgrp docker`, or systemd commands for this rootless setup.

In **every terminal running Docker, Compose, or Make**, select the rootless
socket before any infrastructure command:

```bash
unset DOCKER_CONTEXT
export XDG_RUNTIME_DIR=/run/user/23739
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/docker.sock"

docker info
docker info --format '{{.DockerRootDir}}'
docker info --format '{{json .SecurityOptions}}'
```

Expect the selected data root above and `rootless` in Security Options. Check the
setup guide's container smoke test too. No containers ran in the stopped tests.
After workspace replacement, have the administrator recreate missing private
directories and recheck account IDs. The runtime directory needs lifecycle
cleanup; tmux does not provide recovery after replacement.

## Infrastructure terminal

First choose a [storage plan](local-setup-almalinux10.md#storage-verified-mounts-rootless-engines-and-persistent-data).
The default Compose topology is disposable across workspace replacement.
Persistent service data requires approved storage and explicit bindings before
initialization. The two `/aifs` paths are NFS `soft` mounts and must not be used
as PostgreSQL live data directories in their current configuration. Local
rootless Docker engine storage is a separate concern from service persistence.
Its default volumes are on the disposable data root. Rootless UID/GID mappings
and published ports need actual workload checks; normal cgroup-based Compose
resource limits are unavailable without systemd/delegation here.

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

For access from outside the Pod, use its administrator-provided address/route
and update the backend's server/schema host settings. `firewall-cmd` is installed
but cannot connect to the missing system D-Bus service. Follow the setup guide's
listener, iptables/nftables, Docker forwarding, and Kubernetes network checks;
request targeted administrator changes instead of `firewall-cmd --add-port`.

## Stop and restart

Use `Ctrl+C` in each application terminal. To stop infrastructure while keeping
its containers:

```bash
docker compose -f docker-compose.yml -f docker-compose.override.yml stop
```

For persistence details, see the setup guide before using `down` or deleting
volumes. Do not run `fixtures setup`, index rebuilds, or `make run-e2e-test` as
daily startup checks; they reset data or recreate services.
Keeping containers stopped or giving their volumes names does not make data on
the workspace overlay survive container/Pod replacement.

Leave the daemon session running for the next application restart. `Ctrl+C` in
that session stops the nested engine and affects its workloads. Pod replacement
also loses unsupervised processes; recovery requires the configured workspace
startup mechanism rather than systemd enablement inside the container.

You may put these same commands into separate tmux windows. Killing such a
tmux session stops its applications; detaching with `Ctrl+B`, then `d` leaves
them running.
