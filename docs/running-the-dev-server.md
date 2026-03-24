# Running the Dev Server

## Start

### Step 1 — Infrastructure (Docker)

```bash
cd ~/projects/inspirehep
docker compose -f docker-compose.services.yml -f docker-compose.override.yml up -d es mq db cache s3
```

### Step 2 — Backend

Open a terminal and run (keep it open):

```bash
cd ~/projects/inspirehep/backend
direnv exec . ./scripts/server
```

### Step 3 — UI

Open another terminal and run:

```bash
cd ~/projects/inspirehep/ui
HOST=0.0.0.0 NODE_OPTIONS=--openssl-legacy-provider yarn start
```

### All-in-one (recommended)

The tmux script starts infra, backend, and UI in one command:

```bash
cd ~/projects/inspirehep
./scripts/dev.sh
```

This creates a tmux session named `inspirehep` with four windows:
- `backend` — gunicorn + celery worker
- `ui` — React dev server
- `backoffice` — Django runserver on :8001
- `shell` — free shell at project root

| tmux shortcut | Action |
|---|---|
| `Ctrl+B D` | Detach from session (leaves everything running) |
| `tmux attach -t inspirehep` | Reattach to running session |
| `Ctrl+B 0/1/2` | Switch between windows |

---

## Stop

Kill the tmux session (stops backend and UI):

```bash
tmux kill-session -t inspirehep
```

Stop infrastructure:

```bash
cd ~/projects/inspirehep
docker compose -f docker-compose.services.yml -f docker-compose.override.yml down
```

If not using tmux, `Ctrl+C` in each terminal window is enough to stop the backend and UI.

---

## URLs

Access from other machines on the same intranet (replace IP if your server address changes):

| Service | URL |
|---|---|
| UI | http://192.168.219.191:3000 |
| Backend API | http://192.168.219.191:8000/api/literature/ |
| Backoffice API | http://192.168.219.191:8001/api/ |
| Backoffice admin | http://192.168.219.191:8001/admin/ |
| MinIO console | http://192.168.219.191:9001 |
| Admin login | admin@inspirehep.net / 123456 |
| MinIO login | inspirehep / inspirehep |

> Firewall must allow ports 3000 and 8000:
> ```bash
> sudo firewall-cmd --permanent --add-port=3000/tcp --add-port=8000/tcp
> sudo firewall-cmd --reload
> ```
