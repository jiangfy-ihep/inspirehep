# 本地开发环境搭建 — Alma Linux 9

本指南介绍如何在 Alma Linux 9 上安装和运行 INSPIRE HEP 本地开发环境，
使用 `uv` 管理 Python 版本，`poetry` 管理后端依赖，
`tmux` 保持服务在终端会话间持续运行。

---

## 目录

- [快速开始（搭建完成后）](#快速开始搭建完成后)
- [前置条件](#前置条件)
- [安装步骤](#安装步骤)
  - [1. 系统依赖](#1-系统依赖)
  - [2. 通过 uv 安装 Python 3.11](#2-通过-uv-安装-python-311)
  - [3. 通过 nvm 安装 Node 20](#3-通过-nvm-安装-node-20)
  - [4. Yarn](#4-yarn)
  - [5. Poetry](#5-poetry)
  - [6. pre-commit](#6-pre-commit)
  - [7. direnv](#7-direnv)
  - [8. 后端依赖](#8-后端依赖)
  - [9. 环境变量](#9-环境变量)
  - [10. Docker 覆盖文件](#10-docker-覆盖文件)
  - [11. 启动基础设施](#11-启动基础设施)
  - [12. 初始化数据库和索引](#12-初始化数据库和索引)
  - [13. UI 依赖](#13-ui-依赖)
- [日常使用](#日常使用)
  - [启动开发会话](#启动开发会话)
  - [服务地址](#服务地址)
  - [登录凭据](#登录凭据)
  - [生成 API 令牌](#生成-api-令牌)
  - [导入记录](#导入记录)
  - [运行测试](#运行测试)
  - [停止服务](#停止服务)

---

## 快速开始（搭建完成后）

> 如果你已经完成了安装步骤，可以将本节作为日常参考。

### 启动所有服务

```bash
./scripts/dev.sh
```

此命令启动所有 Docker 基础设施（PostgreSQL、OpenSearch、Redis、RabbitMQ、
MinIO），并打开一个 tmux 会话，其中后端和 UI 已开始运行。如果会话已存在，
则重新附加到该会话。

### 服务地址

| 服务 | 本地地址 | 局域网地址 |
|---|---|---|
| UI | http://localhost:3000 | http://\<主机IP\>:3000 |
| 后端 API | http://localhost:8000 | http://\<主机IP\>:8000 |
| MinIO 控制台 | http://localhost:9001 | http://\<主机IP\>:9001 |
| OpenSearch | http://localhost:9200 | — |

UI 开发服务器绑定到 `0.0.0.0`，因此局域网内任何机器均可访问。

### 管理员凭据

| 账号 | 邮箱 | 密码 |
|---|---|---|
| 应用管理员 | `admin@inspirehep.net` | `123456` |
| MinIO | `inspirehep` | `inspirehep` |

### 常用管理操作

**生成 API 令牌：**
```bash
cd backend && poetry run inspirehep tokens create -n mytoken -u admin@inspirehep.net
```

**导入记录** — 详见下方所有场景。

### 导入记录

导入前必须确保后端服务正在运行。所有命令在 `backend/` 目录下执行。
需要有效的 API 令牌 — 先生成一个：

```bash
poetry run inspirehep tokens create -n mytoken -u admin@inspirehep.net
```

将其设置到 `backend/inspirehep/config.py` 的 `AUTHENTICATION_TOKEN` 中，
或在每条命令中通过 `--token <token>` 传入。

---

**导入所有演示记录**（快速填充本地数据库的最快方式）：

```bash
poetry run inspirehep importer demo-records
```

---

**通过 URL 从 inspirehep.net 导入单条记录：**

```bash
poetry run inspirehep importer records \
  -u https://inspirehep.net/api/literature/20
```

**一次从 inspirehep.net 导入多条记录：**

```bash
poetry run inspirehep importer records \
  -u https://inspirehep.net/api/literature/20 \
  -u https://inspirehep.net/api/literature/1726642
```

适用于所有记录型 — 将 `literature` 替换为 `authors`、`conferences`、
`institutions`、`experiments`、`journals`、`seminars` 或 `data`。

**抓取并保存到本地**（将 JSON 写入 `data/records/<type>/`）：

```bash
poetry run inspirehep importer records \
  -u https://inspirehep.net/api/literature/20 \
  --save
```

---

**从本地 JSON 文件导入：**

```bash
poetry run inspirehep importer records \
  -f data/records/literature/374836.json
```

**一次从多个本地 JSON 文件导入：**

```bash
poetry run inspirehep importer records \
  -f data/records/literature/374836.json \
  -f data/records/authors/999108.json
```

---

**从目录导入**（导入该目录下所有 `.json` 文件）：

```bash
poetry run inspirehep importer records -d data/records/literature
poetry run inspirehep importer records -d data/records/authors
```

---

> `-u`、`-f` 和 `-d` 参数可在一条命令中自由组合、重复使用以混合来源。

**从零重建数据库和索引：**
```bash
docker exec inspirehep-db-1 psql -U postgres -c "CREATE DATABASE inspirehep;" 2>/dev/null || true
cd backend && direnv exec . poetry run inspirehep fixtures setup --with-fixtures
```

### tmux 参考

| 操作 | 命令 |
|---|---|
| 分离（保持运行） | `Ctrl+B` 然后 `d` |
| 重新附加 | `./scripts/dev.sh` |
| 切换窗口 | `Ctrl+B` 然后 `1` / `2` / `3` |
| 终止会话 | `tmux kill-session -t inspirehep` |

### 停止所有服务

```bash
tmux kill-session -t inspirehep
docker compose -f docker-compose.services.yml -f docker-compose.override.yml down
```

---

### 与上游同步

本地适配内容位于 `local` 分支上。`master` 是官方
[inspirehep/inspirehep](https://github.com/inspirehep/inspirehep)
仓库的干净镜像，永远不要直接向其提交。

**远程仓库布局：**

| 远程 | URL | 角色 |
|---|---|---|
| `upstream` | `git@github.com:inspirehep/inspirehep.git` | 官方仓库（仅拉取） |
| `origin` | `git@github.com:jiangfy-ihep/inspirehep.git` | GitHub 分支（主备份） |
| `origin-gitlab` | `git@code.ihep.ac.cn:jiangfy/inspirehep.git` | IHEP GitLab（辅助备份） |

**每当上游发布新提交时执行：**

```bash
export http_proxy=http://192.168.219.196:10810
export https_proxy=http://192.168.219.196:10810

# 1. 拉取新的上游提交到 master
git checkout master
git pull upstream master

# 2. 将 master 推送到两个备份远程
git push origin master
git push origin-gitlab master

# 3. 将本地适配内容变基到新 master 之上
git checkout local
git rebase master

# 4. 将 local 分支备份到两个远程
git push origin local --force-with-lease
git push origin-gitlab local --force-with-lease
```

如果 `rebase` 在 `ui/src/setupProxy.js` 上报冲突，重新应用
`localhost:8000` 目标后执行 `git rebase --continue`。

> `origin-gitlab` 位于内网 — 推送时无需代理，
> 但上述代理环境变量设置也无妨碍（内网地址在 `no_proxy` 中）。

---

## 前置条件

开始前需要已经安装以下内容：

- **Docker**（≥ 24），数据目录设置为 `/data/docker`
- **git**
- **nvm** — https://github.com/nvm-sh/nvm#installing-and-updating
- **curl**

---

## 安装步骤

### 1. 系统依赖

```bash
sudo dnf install -y \
  file-devel \
  postgresql-devel \
  openblas-devel \
  make
```

| 软件包 | 用途 |
|---|---|
| `file-devel` | `python-magic`（libmagic） |
| `postgresql-devel` | psycopg2 构建头文件 |
| `openblas-devel` | numpy / scipy |
| `make` | 项目构建脚本 |

**开放防火墙端口**，使局域网内其他机器可以访问 UI 和
API（Alma Linux 9 默认使用 `firewalld`）：

```bash
sudo firewall-cmd --permanent --add-port=3000/tcp   # UI 开发服务器
sudo firewall-cmd --permanent --add-port=8000/tcp   # 后端 API
sudo firewall-cmd --reload
```

---

### 2. 通过 uv 安装 Python 3.11

项目要求 Python `>=3.11,<3.12`。使用 `uv` 安装和管理，
不触及系统 Python。

如果尚未安装 `uv`：

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

然后安装 Python 3.11：

```bash
uv python install 3.11
```

验证：

```bash
uv run --python 3.11 python --version
# Python 3.11.x
```

---

### 3. 通过 nvm 安装 Node 20

UI 构建脚本使用 `NODE_OPTIONS=--openssl-legacy-provider`，
需要 Node 20（Node 22+ 已不再支持此选项）。

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

通过 `uv` 将 Poetry 作为独立工具安装：

```bash
uv tool install poetry
```

配置其为此项目使用 Python 3.11：

```bash
cd backend
poetry env use $(uv python find 3.11)
```

---

### 6. pre-commit

```bash
uv tool install pre-commit
pre-commit install   # 在项目根目录执行
```

---

### 7. direnv

安装二进制文件：

```bash
curl -sfL https://direnv.net/install.sh | bin_path=~/.local/bin bash
```

将其挂载到 bash（添加到 `~/.bashrc`）：

```bash
echo 'eval "$(direnv hook bash)"' >> ~/.bashrc
source ~/.bashrc
```

---

### 8. 后端依赖

在 `backend/` 目录下执行：

```bash
cd backend
poetry install
```

这将安装约 300 个包，包括所有从 git 获取的 Invenio 分支。
需要访问 GitHub 的网络连接 — 必要时启用代理：

```bash
export http_proxy=http://<代理主机>:<端口>
export https_proxy=http://<代理主机>:<端口>
poetry install
```

---

### 9. 环境变量

创建 `backend/.env` 文件，包含本地覆盖配置：

```bash
# backend/.env
INVENIO_SEARCH_ELASTIC_HOSTS="['localhost:9200']"
INVENIO_S3_HOSTNAME=http://localhost:9000
INVENIO_S3_ACCESS_KEY=inspirehep
INVENIO_S3_SECRET_KEY=inspirehep
INVENIO_FEATURE_FLAG_ENABLE_FILES=True
INVENIO_SERVER_NAME=<主机IP>:8000
INVENIO_JSONSCHEMAS_HOST=<主机IP>:8000
```

将 `<主机IP>` 替换为你机器的局域网 IP 地址（如 `192.168.1.100`）。这两个变量控制生成记录 URL 和 JSON Schema `$id` 字段中的主机名。不设置的话，API 返回的链接会引用 `localhost`，在其他机器上会失效。

创建 `backend/.envrc` 告知 direnv 加载它：

```bash
echo "dotenv" > backend/.envrc
direnv allow backend/
```

此后在任何终端进入 `backend/` 目录都会自动加载这些变量。

> `.env` 和 `.envrc` 都在 gitignore 中 — 可以安全地保留在本地。

---

### 10. Docker 覆盖文件

默认的 `docker-compose.services.yml` 不向主机暴露 PostgreSQL，
也不包含 MinIO。在项目根目录创建 `docker-compose.override.yml`：

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

> MinIO 数据存储在 Docker 命名卷中，与 PostgreSQL
> 和 RabbitMQ 存储数据的方式一致（位于 `/data/docker/volumes/` 下）。

---

### 11. 启动基础设施

```bash
docker compose -f docker-compose.services.yml -f docker-compose.override.yml \
  up -d es mq db cache s3
```

等待所有容器健康就绪：

```bash
docker compose -f docker-compose.services.yml -f docker-compose.override.yml ps
```

预期状态：`db`、`cache`、`es` 为 `healthy`；`mq`、`s3` 为 `Up`。

---

### 12. 初始化数据库和索引

**仅在首次运行时**，需要先创建数据库再执行设置：

```bash
docker exec inspirehep-db-1 psql -U postgres -c "CREATE DATABASE inspirehep;"
```

然后运行完整设置（初始化数据库表、OpenSearch 索引、RabbitMQ
队列、MinIO 存储桶，并创建管理员用户）：

```bash
cd backend
direnv exec . poetry run inspirehep fixtures setup --with-fixtures
```

> 后续运行（如重置后）可跳过 `CREATE DATABASE` 步骤 —
> setup 命令会自动删除并重新创建数据库。

如需独立创建 MinIO 存储桶（如重新启用文件功能后）：

```bash
cd backend
direnv exec . poetry run inspirehep files create-buckets
```

---

### 13. UI 依赖

```bash
cd ui
nvm use 20.0.0
yarn install
```

---

## 日常使用

### 启动开发会话

tmux 辅助脚本启动所有服务，关闭终端后服务仍保持运行：

```bash
./scripts/dev.sh
```

这将创建名为 `inspirehep` 的 tmux 会话，包含三个窗口：

| 窗口 | 内容 |
|---|---|
| `backend` | Gunicorn（端口 8000）+ Celery worker，自动重载 |
| `ui` | React 开发服务器（端口 3000），热更新 |
| `shell` | 项目根目录的空闲终端 |

**tmux 按键参考：**

| 操作 | 按键 |
|---|---|
| 切换窗口 | `Ctrl+B` 然后 `1` / `2` / `3` |
| 分离（保持运行） | `Ctrl+B` 然后 `d` |
| 稍后重新附加 | `./scripts/dev.sh` 或 `tmux attach -t inspirehep` |
| 终止所有 | `tmux kill-session -t inspirehep` |

---

### 服务地址

| 服务 | 本地地址 | 局域网地址 |
|---|---|---|
| **UI**（React 开发服务器） | http://localhost:3000 | http://\<主机IP\>:3000 |
| **后端 API** | http://localhost:8000 | http://\<主机IP\>:8000 |
| **OpenSearch** | http://localhost:9200 | — |
| **MinIO 控制台** | http://localhost:9001 | http://\<主机IP\>:9001 |
| **RabbitMQ 管理界面** | http://localhost:15672 | — |

将 `<主机IP>` 替换为你机器的局域网 IP（在 `backend/.env` 中设置）。端口 3000 和 8000 必须在 firewalld 中开放（见第 1 步）。

> 注意：README 中列出了完整 Docker 部署的 8080 端口。本地运行时，
> 后端在 **8000** 端口，UI 在 **3000** 端口。

---

### 登录凭据

| 服务 | 地址 | 凭据 |
|---|---|---|
| Inspirehep | http://localhost:3000/user/login/local | `admin@inspirehep.net` / `123456` |
| MinIO 控制台 | http://localhost:9001 | `inspirehep` / `inspirehep` |

---

### 生成 API 令牌

```bash
cd backend
poetry run inspirehep tokens create -n <令牌名称> -u admin@inspirehep.net
```

在 API 请求中使用打印的令牌：

```bash
curl -H "Authorization: Bearer <令牌>" http://localhost:8000/api/literature/
```

---

### 导入记录

导入前必须确保后端服务正在运行。使用 `./scripts/dev.sh` 或手动启动。

**从线上 inspirehep.net API 导入：**

```bash
cd backend
poetry run inspirehep importer records \
  -u https://inspirehep.net/api/literature/20 \
  -u https://inspirehep.net/api/literature/1726642
```

添加 `--save` 可同时将抓取的 JSON 写入本地 `data/` 目录。

**从本地 JSON 文件导入：**

```bash
poetry run inspirehep importer records \
  -f data/records/literature/374836.json \
  -f data/records/authors/999108.json
```

**从目录导入：**

```bash
poetry run inspirehep importer records -d data/records/literature
```

**一次性导入所有演示记录：**

```bash
poetry run inspirehep importer demo-records
```

> 需要有效的 API 令牌。可在 `backend/inspirehep/config.py` 中设置
> `AUTHENTICATION_TOKEN`，或通过 `--token <令牌>` 传入。

---

### 运行测试

**后端**（使用 `testmon`，仅运行受变更影响的测试）：

```bash
cd backend
poetry run ./run-tests.sh               # 智能选择（默认）
poetry run ./run-tests.sh --all         # 运行所有测试
poetry run ./run-tests.sh -k test_name  # 运行指定测试
poetry run ./run-tests.sh --pdb         # 失败时进入调试器
```

直接使用 testmon 运行 `py.test`：

```bash
poetry run py.test tests/integration/records --testmon --no-cov
```

**UI**（Jest）：

```bash
cd ui
yarn test         # lint + 单元测试 + 打包体积检查（与 CI 一致）
yarn test:unit    # 监测模式下的单元测试
```

**端到端**（Cypress）：

```bash
# 完整运行（重建所有容器 — 破坏性操作）
make run-e2e-test

# 针对本开发服务器运行
cd e2e
yarn test:dev

# 单个 spec
docker compose run --rm cypress cypress run \
  --browser firefox --headless \
  --env inspirehep_url=http://host.docker.internal:8080 \
  --spec cypress/e2e/jobs.test.js
```

---

### 停止服务

**从 tmux 分离**（服务保持运行）：

```
Ctrl+B 然后 d
```

**停止所有服务：**

```bash
tmux kill-session -t inspirehep
docker compose -f docker-compose.services.yml -f docker-compose.override.yml down
```
