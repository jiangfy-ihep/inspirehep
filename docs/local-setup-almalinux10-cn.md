# Kubernetes 中 AlmaLinux 10 容器的开发环境搭建

[English](local-setup-almalinux10.md) · [日常启动](running-the-dev-server.md)

当前工作区是 **Kubernetes 管理的容器**，用户空间为
**AlmaLinux 10.2 / x86_64**，没有运行 systemd。2026-11-13 在代理沙箱外检查：
PID 1 为 `bash`，`systemd-detect-virt` 返回 `docker`。
`/etc/os-release` 描述容器用户空间，内核由外层主机提供。重新部署后应重新检查，
不能按完整虚拟机处理。

Docker 以嵌套守护进程运行。守护进程可连接与实际容器工作负载可运行是两个
验证步骤；安装 Docker 软件包或确认 OS 版本，不代表整套安装验证成功。

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

上游推荐完整 Docker 工作流。本指南也介绍在工作区内直接运行后端、UI 和
backoffice、通过嵌套 Docker 运行基础设施的方式。这里的原生进程属于工作区，
不是 Kubernetes 节点上的进程；该方式不会启动 Airflow，也不是完整编目工作流。

## 1. 检查主机并选择工作流

除非明确切换目录，所有命令均在仓库根目录执行：

```bash
cat /etc/os-release
uname -m
cat /proc/1/comm
systemd-detect-virt
findmnt -n -o FSTYPE,OPTIONS /sys/fs/cgroup
git status --short --branch
command -v docker poetry node yarn tmux
sysctl vm.max_map_count
```

优先复用已有环境与 Docker 安装，不要替换系统 Python。完整栈约需
18 GB 内存，外层 Pod 的资源限制必须满足要求。检查 PID 1 时读取进程名称，
不要输出完整启动命令，因为其中可能包含初始化凭据。

完整 Docker 环境按 README 和 Makefile 操作。本分支的
`docker-compose.override.yml` 会修改 S3 凭据和存储配置；要使用不加载该
覆盖文件的上游配置，应先完成下面的环境配置。

启动前，先在 Git 忽略的根目录 `.env` 或当前 shell 中配置
`docker-compose.yml` 引用的 Airflow 变量，包括 `FERNET_KEY`。
本指南的原生开发步骤不负责配置完整 Airflow 环境。

```bash
COMPOSE_FILE=docker-compose.yml make run
```

先完成第 2 节的 Docker 检查。该命令会启动并初始化开发服务。
下面的原生开发流程显式使用覆盖文件及其
`inspirehep` S3 凭据。不要交替使用两种配置去重建同一组运行中的容器。

## 2. 需要管理员执行的步骤

软件安装、Docker 启动/访问授权、防火墙检查可能需要 `sudo`，请由用户或
管理员执行并反馈结果。Pod 能力、cgroup 委派、节点内核参数和集群网络由集群
管理员管理；工作区内的 `sudo` 不代表拥有 Kubernetes 节点控制权。
后续应用步骤使用普通开发账号。

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

### 仅在没有 Docker 软件包时安装

以 [Docker RHEL 安装文档](https://docs.docker.com/engine/install/rhel/)
作为软件包安装参考，先检查已有安装：

```bash
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

当前工作区已经安装 Docker Engine/CLI 29.9.3 和 Compose 5.7.1。
重新安装不能解决守护进程或 socket 权限问题。这里没有 systemd 服务管理器，
`systemctl enable --now docker` 无法启动守护进程；创建启用链接也不能让 Pod
重启后自动启动 Docker。

### 启动前先检查守护进程与 socket 权限

```bash
docker context show
ls -l /var/run/docker.sock
id -nG
getent group docker
docker info
```

2026-11-13 检查时，`dockerd` 和 `containerd` 已运行，socket 权限为 `660`，
所有者为 `root:docker`。被检查会话访问被拒绝：账号已经出现在 Docker 用户组
数据库中，但已有进程尚未取得该附加组。这与之前 socket 不存在的错误不同。
不要为解决权限错误而启动第二个守护进程。

如果尚未授予组成员身份，由用户/管理员在开发账号下运行：

```bash
sudo usermod -aG docker "$(id -un)"
```

如果账号已经列在组内，刷新当前终端即可，不必重复添加：

```bash
newgrp docker
id -nG
docker info
```

`newgrp` 启动子 shell；新的 SSH 登录也会加载更新后的用户组。已有 shell、
tmux 服务进程和其他长期运行进程仍保留旧组列表。Docker 用户组具有相当于 root
的控制能力，如不符合站点策略应采用获准方案。不要把 socket 改成所有人可写。

### 仅在守护进程未运行时手动启动

确认没有守护进程后，请用户/管理员在独立终端中按
[Docker 手动启动说明](https://docs.docker.com/engine/daemon/start/)运行：

```bash
sudo dockerd
```

它以前台方式运行，日志直接输出到该终端，请保持终端打开。需要断开 SSH 后继续
运行时，先用 `tmux new-session -s inspirehep-docker` 创建专用会话，再在其中
运行同一命令。按 `Ctrl+B`、再按 `d` 分离，用
`tmux attach-session -t inspirehep-docker` 重新连接。保持单个使用站点批准配置的
守护进程，不要每次启动应用都启动新的 Docker。

在另一个具有 socket 访问权限的终端验证服务端，再测试实际容器：

```bash
docker version
docker compose version
docker info
docker info --format '{{.DockerRootDir}}'
docker run --rm hello-world
```

最后一条命令会下载并运行镜像，文档检查时没有执行。通过后只能证明基础容器
工作负载可运行，不能代替完整 Compose 验证。在守护进程终端按 `Ctrl+C` 会停止
Docker。Pod 替换后的自动恢复需要集群管理员配置获准的启动/进程管理机制；
tmux 可应对 SSH 断开，不能跨 Pod 替换存活。

### 嵌套 Docker 的前置条件与错误处理

当前 `/sys/fs/cgroup` 是只读的 cgroup v2 挂载。PID 1 的能力集中包含
`CAP_SYS_ADMIN` 与 `CAP_NET_ADMIN`，但这不证明所有内部容器操作可用。
守护进程可能成功启动，而工作负载在创建 cgroup、挂载或桥接网络时失败。

如启动或冒烟测试失败，将首个错误交给集群管理员，检查获准的嵌套容器能力与
安全配置、cgroup 访问/委派、存储驱动/文件系统以及网络。不要把重新挂载节点
cgroup、启用全面 privileged 模式或关闭 Docker 防火墙管理作为通用修复。
工作区内调整用户组不能解决这些集群层面的限制。

不要假定 Docker 数据目录是 `/data/docker`，不要把它放进共享项目目录，也不要
直接对已有 Docker 数据切换存储驱动。合适的存储及持久化方案由管理员提供；
工作区可写层可能随 Pod 替换而消失。如不支持嵌套 Docker，应使用管理员提供的
引擎或 Kubernetes 基础设施。远程引擎需要匹配的拓扑：`localhost` 端口及
Compose 绑定挂载属于引擎所在机器，不会自动指向本工作区。后续命令假定工作区
内的嵌套引擎已经可用。

### 存储：已验证挂载、rootless Podman 与持久化数据

2026-11-13 在代理沙箱外执行了以下存储检查：

```bash
findmnt -n -o TARGET,FSTYPE,OPTIONS -T /aifs/user/data/jiangfayu
findmnt -n -o TARGET,FSTYPE,OPTIONS -T /aifs/user/home/jiangfayu
findmnt -n -o TARGET,FSTYPE,OPTIONS -T /tmp
findmnt -n -o TARGET,FSTYPE,OPTIONS -T /var/tmp
df -h /tmp /var/tmp
```

| 路径 | 已观察的文件系统 | 用途 |
| --- | --- | --- |
| `/aifs/user/data/jiangfayu` | 可写 NFSv4，使用 `soft` 挂载 | 共享源文件、导入数据、已验证的备份 |
| `/aifs/user/home/jiangfayu` | 可写 NFSv4，使用 `soft` 挂载 | 用户文件与配置 |
| `/tmp`、`/var/tmp` | 同一个挂载在 `/` 的可写 `overlay` 文件系统 | 工作区本地的可丢弃存储 |
| `/var/lib/docker` | 同一容器 overlay，当前 Docker 数据根目录 | 引擎数据和默认卷，不具备 Pod 级持久化保证 |

检查时 overlay 报告约 766 GiB 可用，这是当时共享文件系统的剩余空间，不是
用户配额或 Kubernetes 临时存储保证。`/tmp` 与 `/var/tmp` 不是两份独立空间。
工作区容器/Pod 替换后内容可能消失，在 `/var/tmp` 创建目录不会自动获得持久性。

#### PostgreSQL 与 NFS soft 挂载限制

不要将 PostgreSQL 的运行数据目录放在当前两个 `/aifs` 挂载上。PostgreSQL
要求 NFS 数据文件系统使用 `hard`；网络故障时 `soft` 可能返回 I/O 错误。
NFS 并非一概不支持，但用于数据库前必须由管理员验证挂载、服务端导出与 fsync
持久化行为以及权限。参考
[PostgreSQL NFS 要求](https://www.postgresql.org/docs/14/creating-cluster.html#CREATING-CLUSTER-NFS)。

挂载或导出修改由存储/集群管理员处理，不要在本工作区重新挂载共享 `/aifs`。
改为 `hard` 可以解决 PostgreSQL 的这一项要求，但不会让 NFS 变成 rootless
Podman 可用的容器存储文件系统。

数据库 dump、导入 JSON 和备份可以存放在 NFS，例如拟议目录
`/aifs/user/data/jiangfayu/inspirehep-data/backups/`。检查备份命令结果并测试恢复，
使用数据库专用备份工具；复制正在运行的 PostgreSQL 数据目录不能替代正确的
备份流程。文档更新没有创建该示例目录。

#### Rootless Podman 存储与应用数据是不同问题

Podman 尚未安装或验证，这些发现不会把仓库切换到 Podman。
默认 rootless 存储 `$HOME/.local/share/containers/storage` 在当前环境位于 NFS。
Podman 的镜像/容器存储（`graphroot`）应改为受支持的非 NFS 存储；配置文件
可以留在 NFS home 中。参考
[Podman rootless 存储限制](https://docs.podman.io/en/latest/markdown/podman.1.html#note-unsupported-file-systems-in-rootless-mode)。

`/var/tmp/jiangfayu-podman/storage` 这样的私有目录是可丢弃引擎存储的候选，
不是已验证或持久化的配置。试用前先检查已有 `storage.conf`，为无 systemd
环境准备用户独占、权限为 `0700` 的非 NFS 运行时目录，例如
`/var/tmp/jiangfayu-podman/run`。没有登录服务管理器时，`XDG_RUNTIME_DIR` 可能
未设置，需要显式配置并验证，不能依赖 systemd 自动创建路径。
安装所需 Podman、网络及 FUSE 软件包后再进行试用。
按需使用 `fuse-overlayfs` 支持 rootless 镜像分层；overlay 底层仍需实际存储和
容器冒烟测试。不要对有数据的引擎随意更改 graphroot/驱动，也不要只通过
`alias docker` 就认定服务兼容。

应用数据绑定挂载与引擎存储是不同问题。非 NFS graphroot 不会让 PostgreSQL
挂载数据自动持久化，也不会修复 NFS `soft` 挂载。Rootless UID/GID 映射必须
匹配数据目录权限；即使镜像存储放在本地，只读 cgroup 与 Compose 资源限制问题
仍然需要验证。

#### 持久化服务需要明确存储方案

| 数据 | 建议位置 |
| --- | --- |
| 源代码、导入快照、数据库 dump/备份 | 现有 `/aifs/user/data/jiangfayu`，按其保留与备份策略处理 |
| 可重新下载的镜像、临时容器层 | 私有非 NFS 工作区存储，未另外配置持久化时视为可丢弃 |
| PostgreSQL 与 OpenSearch 运行数据 | 管理员提供、符合服务要求的持久化文件系统 |
| 必须跨替换保留的 MinIO 对象、RabbitMQ 队列、Redis 状态 | 显式持久化挂载或托管服务，并配置各服务的持久化选项 |

向管理员申请由合适块存储 StorageClass 提供的文件系统模式 PVC，格式化为
ext4/XFS 并挂载到工作区，或使用获准的外部数据库/搜索服务。拟议挂载点为
`/persistent/inspirehep`，它目前不存在，单独 `mkdir` 不会创建持久卷。各服务
使用独立数据目录，按实际容器 UID/GID 映射设置所有权，初始化前确认文件系统
及挂载边界。

管理员还需确认容量、Pod 重新调度/访问要求、PVC/PV 删除及回收策略，以及
备份恢复方案。PVC 可以比 Pod 存活更久，但本身不是备份，也不保证不会被删除。
参考 [Kubernetes 持久卷](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)。

保存重要数据前，必须将获准存储显式接入 Compose。当前覆盖文件中的
`minio-data` 是普通命名卷，不是 Kubernetes PVC；PostgreSQL/OpenSearch
服务没有显式绑定外部持久化数据挂载。Docker/Podman 命名卷的持久性取决于
引擎底层存储；引擎数据位于工作区 overlay 时，仅有卷名不能防止替换后丢失。
在实施存储方案并验证恢复前，提供的 Compose 配置应视为可丢弃的开发基础设施。

### OpenSearch 内核参数

OpenSearch 要求 `vm.max_map_count` 至少为 `262144`，当前共享内核已满足，
无需修改：

```bash
sysctl vm.max_map_count
```

重新调度后如值过低，应请集群管理员配置相关节点的内核参数和持久化方式。
在本容器写 sysctl 文件不等于配置节点启动，也不会创建 systemd 服务。

### 检查 firewall-cmd 与实际网络层次

2026-11-13 执行了以下只读检查：

```bash
command -v firewall-cmd
firewall-cmd --state
ls -l /run/dbus/system_bus_socket
ss -ltn
```

`firewall-cmd` 和 firewalld 2.4.3 已安装，但 firewalld 未运行，系统 D-Bus
socket 不存在。状态查询返回：

```text
Error: DBUS_ERROR: Failed to connect to socket /run/dbus/system_bus_socket: No such file or directory
```

`firewall-cmd` 通过 D-Bus 与 firewalld 通信，仅安装 CLI 不会启动服务。
因此 `--add-port`、`--reload` 不是本工作区适用的开放端口方式。不要仅为执行
这些命令就启动 D-Bus/firewalld，也不要以为 `firewall-offline-cmd` 会实时
修改规则；离线配置本身不会应用运行时规则。

需要区分以下层次：

1. 应用必须在工作区网络命名空间中监听所需地址和端口，通过 `ss -ltn` 检查，
   并先在工作区内用 `curl` 验证。
2. 工作区可能已经有初始化配置创建的 iptables/nftables 输入规则。没有
   firewalld 不等于没有这些规则；嵌套 Docker 还会建立内部容器转发/NAT 规则。
3. Kubernetes CNI 路由、NetworkPolicy，以及集群的 Service/Ingress 或其他
   工作区接入机制决定 Pod 外部访问。内部 `docker -p` 在工作区命名空间发布
   端口，不会自动创建外部 Kubernetes 访问端点。

端口不通时，请用户/管理员提供下面的只读规则列表，再在正确层次请求精确修改：

```bash
sudo iptables -S
sudo iptables -t nat -S
sudo nft list ruleset
```

这些需要权限的规则查询在文档检查时没有执行。原生 UI/API/backoffice 分别可能
需要 3000/8000/8001，Docker 基础设施端口应另外检查。保留 SSH 和 Docker 规则，
不要清空规则表或插入无条件放行规则。持久化修改应由管理员纳入工作区/集群配置。
参考 [Docker 网络规则](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
及 [Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/)。

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

初始化前，按上方存储章节选择可丢弃还是持久化服务数据。下列命令不会创建 PVC
或添加持久化数据绑定；用于可丢弃开发环境，或先接入管理员批准的持久化配置。

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

| 工作区端点 | 服务 |
| --- | --- |
| `localhost:5432` | 后端 PostgreSQL，数据库 `inspirehep` |
| `localhost:5434` | backoffice PostgreSQL，数据库 `backoffice` |
| `localhost:6379` | Redis |
| `localhost:5672`、`localhost:15672` | 后端 RabbitMQ 与管理界面 |
| `localhost:5673`、`localhost:15673` | backoffice RabbitMQ 与管理界面 |
| `localhost:9200` | OpenSearch |
| `localhost:9000`、`localhost:9001` | S3 API 与 MinIO 控制台 |

Compose 中这些基础设施端口默认绑定所有工作区网卡，表格并不表示仅限本机。
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
同样的持久化配置。即使执行 `dc stop`，工作区替换也可能丢失 overlay 上的数据；
持久化服务应遵循上方的存储方案。

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
- [Docker 手动启动](https://docs.docker.com/engine/daemon/start/)
- [firewall-cmd 客户端与 D-Bus](https://firewalld.org/documentation/man-pages/firewall-cmd.html)
- [Kubernetes 容器安全限制](https://kubernetes.io/docs/concepts/security/linux-kernel-security-constraints/)
- [Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [PostgreSQL NFS 挂载与导出要求](https://www.postgresql.org/docs/14/creating-cluster.html#CREATING-CLUSTER-NFS)
- [Podman rootless 存储要求](https://docs.podman.io/en/latest/markdown/podman.1.html#note-unsupported-file-systems-in-rootless-mode)
- [Kubernetes 持久卷](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [PostgreSQL dump 备份](https://www.postgresql.org/docs/14/backup-dump.html)

2026-11-13 在代理沙箱外检查了工作区 PID 1、用户空间版本、已安装软件包、
只读 cgroup 挂载、socket 所有权、用户组和内核参数。使用账号已有 Docker
组成员身份的子 shell 成功执行了只读查询：服务端 29.9.3，存储驱动 `overlayfs`，
cgroup 驱动 `cgroupfs`，cgroup 版本 2。原长期运行会话仍被拒绝访问 socket。
firewalld 状态查询返回了上文记录的 D-Bus 错误。

存储检查还确认两个 `/aifs` 挂载均使用 `soft`，`/tmp` 与 `/var/tmp` 共用工作区
overlay，Docker 的 `/var/lib/docker` 也位于该 overlay。Podman 尚未安装，
`/persistent/inspirehep` 不存在；没有部署或验证任何候选持久化数据存储。

这些检查未改变守护进程运行状态、防火墙规则、Pod 或节点设置。
`hello-world` 冒烟测试、Compose 工作负载、应用安装/测试、需要权限的防火墙
规则列表和集群外部访问仍未验证。请让用户/管理员执行相关操作并记录结果后，
再判断端到端环境是否就绪。
