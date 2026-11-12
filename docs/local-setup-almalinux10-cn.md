# AlmaLinux 10 本地开发环境搭建

[English](local-setup-almalinux10.md) · [日常启动](running-the-dev-server.md)

本指南适用于 **AlmaLinux 10.x / x86_64**。2026-11-12 检查时，当前主机的
`/etc/os-release` 显示 **AlmaLinux 10.2**。这只确认主机版本，不代表已完成
安装验证；未来升级到其他主版本时，需要重新核对步骤。

版本以当前仓库配置为准：

| 组件 | 当前配置 |
| --- | --- |
| 后端与 backoffice | Python 3.11，Poetry 管理环境与依赖 |
| Poetry | 两个锁文件均由 2.4.1 生成 |
| UI | Node 24.15.0、Yarn Classic、React 19、Vite、Vitest |
| OpenSearch | 3.9.0，插件见 `docker/opensearch.Dockerfile` |
| 数据库 | 后端 PostgreSQL 14.13；backoffice PostgreSQL 15.15 |
| 其他基础设施 | Redis 8、RabbitMQ 4.2、S3 兼容存储 |
| 工作流 | Airflow 3.4.0 基础镜像，通过仓库容器运行 |

上游推荐完整 Docker 工作流。本指南也介绍在主机上运行后端、UI 和
backoffice、通过 Docker 运行基础设施的方式；后者不会启动 Airflow，
也不等于完整的编目工作流。

## 1. 检查主机并选择工作流

除非明确切换目录，所有命令均在仓库根目录执行：

```bash
cat /etc/os-release
uname -m
git status --short --branch
command -v docker poetry node yarn tmux
sysctl vm.max_map_count
```

优先复用已有环境与 Docker 安装，不要替换系统 Python。完整栈约需
18 GB 内存，具体要求见根目录 README。

完整 Docker 环境按 README 和 Makefile 操作。本分支的
`docker-compose.override.yml` 会修改 S3 凭据和存储配置；要使用不加载该
覆盖文件的上游配置，应先完成下面的环境配置。

启动前，先在 Git 忽略的根目录 `.env` 或当前 shell 中配置
`docker-compose.yml` 引用的 Airflow 变量，包括 `FERNET_KEY`。
本指南的原生开发步骤不负责配置完整 Airflow 环境。

```bash
COMPOSE_FILE=docker-compose.yml make run
```

该命令会启动并初始化开发服务。下面的原生开发流程显式使用覆盖文件及其
`inspirehep` S3 凭据。不要交替使用两种配置去重建同一组运行中的容器。

## 2. 需要管理员执行的步骤

软件安装、Docker 服务和访问授权、内核参数、防火墙修改可能需要 `sudo`。
请由用户或管理员执行适用的命令并反馈结果；后续步骤使用普通开发账号。

### 编译与运行依赖

```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --set-enabled crb
sudo dnf install -y \
  gcc gcc-c++ make pkgconf-pkg-config libpq-devel \
  file-libs gettext poppler-utils git curl jq tmux
```

`libpq-devel` 提供 PostgreSQL 客户端头文件和 `pg_config`，用于编译
backoffice 的 `psycopg[c]`；`file-libs` 提供 `python-magic` 加载的运行库，
仅加载 libmagic 不需要 `file-devel`。如镜像源缺少某个包，先检查启用的仓库，
可用 `dnf provides '*/pg_config'` 确认提供者。

NumPy 通常使用二进制 wheel。只有实际源码编译报错需要时，才安装
`openblas-devel` 或其他明确缺失的头文件，不要随意升级锁定的 Python 依赖。

### 未安装 Docker 时

参考 [Docker 的 RHEL 安装文档](https://docs.docker.com/engine/install/rhel/)。
先检查已有容器运行时，不要把卸载已有软件作为常规步骤：

```bash
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
```

如果管理员选择通过 Docker 用户组授权，在开发账号下执行以下命令后重新登录：

```bash
sudo usermod -aG docker "$(id -un)"
```

该组具有相当于 root 的控制能力；如不符合站点策略，应使用管理员批准的方案。
以普通用户确认访问：

```bash
docker version
docker compose version
docker info --format '{{.DockerRootDir}}'
```

不要假定 Docker 数据根目录是 `/data/docker`，也不要在应用安装过程中迁移它。
Podman 提供的 `docker` 命令不代表已验证本仓库的 Docker Compose 工作流。

### OpenSearch 内核参数

`vm.max_map_count` 至少应为 `262144`。当前主机已经是该值，无需修改。
仅在其他主机的值过低时，请管理员执行：

```bash
printf '%s\n' 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-inspirehep.conf
sudo sysctl -p /etc/sysctl.d/99-inspirehep.conf
```

### 按需开放网络访问

仅通过本机浏览器访问时，不需要向局域网开放应用端口。需要远程访问时，
先由管理员检查实际防火墙和网卡所属区域：

```bash
sudo firewall-cmd --state
sudo firewall-cmd --get-active-zones
```

若 firewalld 已启用，将下面变量改成实际服务目标客户端的区域：

```bash
INTRANET_ZONE=replace-with-the-actual-zone
sudo firewall-cmd --zone="$INTRANET_ZONE" --permanent --add-port=3000/tcp
sudo firewall-cmd --zone="$INTRANET_ZONE" --permanent --add-port=8000/tcp
sudo firewall-cmd --zone="$INTRANET_ZONE" --permanent --add-port=8001/tcp
sudo firewall-cmd --reload
```

不需要远程 backoffice 时省略 8001。若没有 firewalld，应反馈情况，按主机原有
防火墙策略处理，不要直接安装并启用新的防火墙。不要清空 iptables/nftables
或关闭 SELinux。Docker 自己管理桥接网络规则，容器发布端口还应由管理员根据
[Docker 防火墙模型](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
检查访问范围。

## 3. 用户工具与项目环境

Python 环境和依赖继续由 **Poetry** 管理。uv 仅用于安装 Python 解释器和
独立工具；不要在此仓库使用 `uv sync`、`uv add` 或直接 `pip install` 管理依赖。

如果没有 uv，先按其[安装文档](https://docs.astral.sh/uv/getting-started/installation/)
安装到用户目录。然后执行：

```bash
uv python install 3.11
uv python find 3.11
uv tool install --python 3.11 'poetry==2.4.1'
export PATH="$HOME/.local/bin:$PATH"
poetry --version
```

2.4.1 与锁文件生成版本一致，Dockerfile 另有各自固定的 Poetry 版本。
不要只为消除工具版本提示而重新生成锁文件；已有 Poetry 或项目环境时，先检查
并复用。不要使用无关项目的已激活虚拟环境。

在仓库根目录安装两个项目的锁定依赖：

```bash
(cd backend && poetry env use "$(uv python find 3.11)" && poetry install --with dev)
(cd backoffice && poetry env use "$(uv python find 3.11)" && poetry install --with dev)
(cd backend && poetry run python --version && poetry env info --path)
(cd backoffice && poetry run python --version && poetry env info --path)
```

不需要执行 `poetry update`。安装并加载用户级
[nvm](https://github.com/nvm-sh/nvm#installing-and-updating)，再配置 UI：

```bash
nvm install 24.15.0
nvm use 24.15.0
npm install --global yarn@1.22.22
(cd ui && yarn install --frozen-lockfile)
```

通过 nvm 安装 Node/Yarn 不需要 `sudo npm`。Vite 不再需要旧的
`--openssl-legacy-provider`。`record-editor/` 是旧版 Angular 应用，工具链独立；
新的 React 编辑器位于 `ui/src/editor/`。

Python 格式检查工具可作为独立用户工具安装：

```bash
uv tool install --python 3.11 pre-commit
pre-commit install
```

## 4. 启动原生开发所需基础设施

使用主 Compose 文件，它提供 RabbitMQ 主机端口以及独立的 backoffice
数据库和消息代理。需要运行基础设施命令的每个终端都应在仓库根目录定义：

```bash
dc() { docker compose -f docker-compose.yml -f docker-compose.override.yml "$@"; }
dc config --quiet
dc up -d db db-backoffice cache mq backoffice-mq es s3
dc ps
```

等待数据库、缓存、搜索与 S3 健康检查通过；错误时检查 `dc logs es s3 mq`。
这里使用已提交覆盖文件中的 MinIO 凭据 `inspirehep` / `inspirehep`。

读取主配置时可能出现未设置 `FERNET_KEY` 的提示，即使该命令并不启动 Airflow。
启动任何工作流服务前，应先完成对应配置。

| 主机端点 | 服务 |
| --- | --- |
| `localhost:5432` | 后端 PostgreSQL，数据库 `inspirehep` |
| `localhost:5434` | backoffice PostgreSQL，数据库 `backoffice` |
| `localhost:6379` | Redis |
| `localhost:5672`、`localhost:15672` | 后端 RabbitMQ 与管理界面 |
| `localhost:5673`、`localhost:15673` | backoffice RabbitMQ 与管理界面 |
| `localhost:9200` | OpenSearch |
| `localhost:9000`、`localhost:9001` | S3 API 与 MinIO 控制台 |

Compose 中这些基础设施端口默认绑定所有主机网卡，表格并不表示仅限本机。
共享主机应由管理员限制暴露范围。`db`、`es`、`hep-web` 等是容器 DNS 名称，
主机上的应用应使用表格中的主机端点。

旧的 `scripts/dev.sh` 使用 `docker-compose.services.yml` 加覆盖文件启动
简化配置，不发布 RabbitMQ，也不提供独立的 backoffice 数据库/消息代理。
不要用它初始化或重新配置这里的拓扑，请使用下方手动启动流程。

## 5. 配置原生应用环境

创建 Git 忽略的 `backend/.env` 与 `backoffice/.env`，使用可由 Bash
`source` 加载的赋值格式，不要把私有值写入已跟踪的配置文件。

`backend/.env` 示例：

```bash
INVENIO_SQLALCHEMY_DATABASE_URI='postgresql+psycopg2://postgres:postgres@localhost:5432/inspirehep'
INVENIO_SEARCH_ELASTIC_HOSTS="['localhost:9200']"
INVENIO_BROKER_URL='amqp://guest:guest@localhost:5672/'
INVENIO_CELERY_BROKER_URL='amqp://guest:guest@localhost:5672/'
INVENIO_CELERY_RESULT_BACKEND='redis://localhost:6379/2'
INVENIO_CACHE_REDIS_URL='redis://localhost:6379/0'
INVENIO_ACCOUNTS_SESSION_REDIS_URL='redis://localhost:6379/1'
INVENIO_S3_HOSTNAME='http://localhost:9000'
INVENIO_S3_ACCESS_KEY='inspirehep'
INVENIO_S3_SECRET_KEY='inspirehep'
AWS_DEFAULT_REGION='us-east-1'
INVENIO_FEATURE_FLAG_ENABLE_FILES=True
INVENIO_FEATURE_FLAG_ENABLE_FULLTEXT=True
INVENIO_FEATURE_FLAG_ENABLE_LOCAL_LOGIN=True
INVENIO_SERVER_NAME='localhost:8000'
INVENIO_JSONSCHEMAS_HOST='localhost:8000'
INVENIO_SECRET_KEY='replace-with-a-generated-local-secret'
INVENIO_AUTHENTICATION_TOKEN='replace-with-a-generated-local-token'
```

在 `backend/` 中使用
`poetry run python -c 'import secrets; print(secrets.token_hex(32))'`，为最后
两个设置分别生成值，仅保存在忽略的文件中。令牌应在初始化前设置，因为 fixtures
会把它存入本地管理员的 API 令牌记录。

供局域网客户端使用时，将 `INVENIO_SERVER_NAME` 和
`INVENIO_JSONSCHEMAS_HOST` 改为客户端可访问的主机名/IP（含 8000 端口）。

`backoffice/.env` 示例：

```bash
DJANGO_SETTINGS_MODULE='config.settings.local'
DJANGO_READ_DOT_ENV_FILE=False
USE_DOCKER=no
POSTGRES_URI='postgresql://postgres:postgres@localhost:5434/backoffice'
REDIS_URL='redis://localhost:6379/4'
CELERY_BROKER_URL='amqp://guest:guest@localhost:5673/'
OPENSEARCH_HOST='localhost:9200'
OPENSEARCH_INDEX_PREFIX='backoffice-backend-local'
INSPIREHEP_BASE_URL='http://localhost:8000'
AIRFLOW_BASE_URL='http://localhost:8070'
FRONTEND_LOGIN_SUCCESS='http://localhost:3000/backoffice'
```

backoffice 默认读取面向容器的 `.envs/local/.django` 和 `.postgres`。
`DJANGO_READ_DOT_ENV_FILE=False` 防止在原生环境中加载这些 Docker 默认值。
基础设施模式未启动 Airflow，该地址只有在配置并启动工作流服务后才可用。

Poetry 不会自动加载这些 `.env`。每个应用终端进入对应目录后，都要执行
`set -a; source ./.env; set +a` 再运行应用命令。已有 direnv 配置也可使用，
但不要假定已经安装或启用。

## 6. 首次初始化

主 Compose 配置会在全新数据库存储首次启动时创建对应数据库。先检查：

```bash
dc exec -T db psql -U postgres -tAc "SELECT datname FROM pg_database WHERE datname='inspirehep'"
dc exec -T db-backoffice psql -U postgres -tAc "SELECT datname FROM pg_database WHERE datname='backoffice'"
```

如果已有存储早于该配置，且对应数据库缺失，只执行缺失数据库的创建命令：

```bash
dc exec -T db psql -U postgres -c 'CREATE DATABASE inspirehep;'
dc exec -T db-backoffice psql -U postgres -c 'CREATE DATABASE backoffice;'
```

**后端 setup 是重置操作，不是日常启动或数据迁移。**
`backend/inspirehep/fixtures.py` 会清空 Redis、重建数据库表和搜索索引、清空
队列，并创建存储桶和测试用户。仅用于全新的可丢弃开发实例，并先停止使用同一
Redis 的其他应用。

后端终端：

```bash
cd backend
set -a
source ./.env
set +a
poetry run ./scripts/setup
poetry run inspirehep importer demo-records
```

独立的 backoffice 终端：

```bash
cd backoffice
set -a
source ./.env
set +a
poetry run python manage.py migrate
poetry run python manage.py create_groups
poetry run python manage.py loaddata backoffice/users/fixtures/users.json
poetry run python manage.py opensearch index rebuild --force
poetry run python manage.py opensearch document index --force
```

索引 rebuild 同样会替换已有索引，只用于首次设置或主动重建。这些步骤没有配置
全部 Airflow 令牌、工作流 fixtures 和异步 backoffice worker；完整端到端场景
应使用完整 Docker 工作流。

## 7. 日常启动与验证

按[运行开发服务](running-the-dev-server.md)启动三个应用终端；普通重启不执行
setup/reset。也可把相同命令放进自己的 tmux 窗口。

| 应用 | 地址 | 测试账号 |
| --- | --- | --- |
| UI | `http://localhost:3000/user/login/local` | `admin@inspirehep.net` / `123456` |
| 后端 API | `http://localhost:8000/api/literature/` | 按需使用本地 API 令牌 |
| backoffice 管理界面 | `http://localhost:8001/admin/` | `admin@admin.com` / `admin` |
| MinIO 控制台 | `http://localhost:9001` | `inspirehep` / `inspirehep` |

```bash
curl --fail http://localhost:8000/api/literature/
curl --fail http://localhost:3000/api/literature/
curl --fail http://localhost:9200/_cluster/health
```

第二个请求同时检查 Vite 的 `/api` 代理。还需在浏览器验证登录，导入后检查搜索
结果及后端 worker 日志；仅安装依赖成功不代表后台处理已验证。

## 8. 导入、测试、停止与同步

导入命令在已加载 `.env` 的后端终端执行。CLI 直接写数据库和索引；本地文件
导入不要求运行 HTTP 服务，也不要求 API 令牌：

```bash
poetry run inspirehep importer records -f data/records/literature/374836.json
poetry run inspirehep importer records -d data/records/literature
```

URL 导入中的 `--token` 用于访问**来源 API**；本地生成的令牌不能授予
inspirehep.net 的权限：

```bash
poetry run inspirehep importer records \
  -u https://inspirehep.net/api/literature/20 --token "$SOURCE_API_TOKEN"
```

`-u` 和 `-f` 可重复，`-d` 每次接受一个目录。`import_records.sh` 与 `IMPORT.md`
是指向独立 `../curation_stats/` 项目的软链接，使用前确认目标存在。

| 目录 | 检查命令 |
| --- | --- |
| `backend/` | `poetry run ./run-tests.sh --all` |
| `backoffice/`，已加载环境 | `poetry run pytest .` |
| `ui/` | `yarn test:unit`；完整检查用 `yarn test` |
| 根目录，完整工作流容器已启动 | `docker compose -f docker-compose.yml exec -T airflow-worker pytest tests` |
| 根目录 | `pre-commit run --files <changed-files>` |

后端集成测试需要对应服务和测试数据库，运行前阅读 `backend/tests/conftest.py`
及各测试套件的 fixtures。默认 testmon 选择受影响的集成测试，`--all` 关闭选择。
UI 使用 Vitest，`test:unit` 只运行一次；`yarn test` 还包括 lint、类型、覆盖率和
打包体积检查。`make run-e2e-test` 会重新创建并初始化容器，不应作为已有实例的
无副作用检查。Cypress 默认访问 8080；原生 UI 为 3000，必须显式设置测试 URL，
并启动测试需要的 backoffice/工作流服务。

日常停止时对应用执行 `Ctrl+C`，基础设施使用 `dc stop` 保留容器。
`dc down` 会删除容器，匿名数据库卷未必会在下一次 `up` 时重新挂载。删除容器或
卷前先备份；本地覆盖文件只为 MinIO 显式定义了命名卷，不要假定所有服务都有
同样的持久化配置。

保持 `master` 跟踪 `upstream/master`、`dev` 跟踪 `origin/dev`：

```bash
git fetch upstream
git switch master
git merge --ff-only upstream/master
git switch dev
git pull --ff-only origin dev
git merge upstream/master
# 解决冲突并检查后再发布。
git push origin dev
```

先确保工作区干净，不强制推送已发布历史。应用冲突按上游当前实现处理；
`.gitignore` 合并双方规则并去重。

## 参考与验证范围

- [AlmaLinux 仓库与 CRB](https://wiki.almalinux.org/repos/AlmaLinux)
- [RHEL 10 包清单（含 libpq-devel）](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/pdf/package_manifest/Red_Hat_Enterprise_Linux-10-Package_manifest-en-US.pdf)
- [Docker RHEL 安装文档](https://docs.docker.com/engine/install/rhel/)
- [OpenSearch Docker 前置条件](https://docs.opensearch.org/3.9/install-and-configure/install-opensearch/docker/)
- [firewalld 端口配置](https://firewalld.org/documentation/howto/open-a-port-or-service)

已核对仓库配置、当前 OS、软件包清单和内核参数；尚未在此主机完成整套安装、
容器启动及应用测试。缺少前置依赖时，请先让管理员执行对应步骤，再根据实际
启动与测试结果记录验证状态，不能把本指南当作端到端安装成功的证明。
