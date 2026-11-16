# Kubernetes 中 AlmaLinux 10 容器的开发环境搭建

[English](local-setup-almalinux10.md) · [日常启动](running-the-dev-server.md)

> **用户于 2026-11-16 要求停止测试，将改用其他机器。** 本 Pod 的 rootless
> Docker 启动失败，独立的嵌套 overlay 存储检查也失败，没有启动本地 INSPIRE。
> [第 9 节](#9-实际测试结果与阻碍2026-11-16)记录结果与阻碍。以下步骤保留为
> 尝试过的配置说明，不代表可用安装；没有新请求不要恢复运行测试或软件/集群变更。

当前工作区是 **Kubernetes 管理的容器**，用户空间为
**AlmaLinux 10.2 / x86_64**，没有运行 systemd。2026-11-13 在代理沙箱外检查：
PID 1 为 `bash`，`systemd-detect-virt` 返回 `docker`。
`/etc/os-release` 描述容器用户空间，内核由外层主机提供。重新部署后应重新检查，
不能按完整虚拟机处理。

本次尝试采用无需 systemd 的 rootless Docker 嵌套守护进程。守护进程可连接与
实际容器工作负载可运行是两个验证步骤；安装 Docker 软件包或确认 OS 版本，
不代表整套安装验证成功。

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

软件安装、初始运行时/数据目录准备、防火墙检查可能需要 `sudo`，请由用户或
管理员执行并反馈结果。Rootless Docker 本身启动无需 sudo。Pod 能力、cgroup 委派、节点内核参数和集群网络由集群
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

### Rootless Docker：一次性管理员准备

本次配置尝试使用 rootless Docker：守护进程和容器应运行在开发账号的用户
命名空间中。Docker 用户组仅允许访问 root 守护进程，访问此 rootless socket 不需要该组。
参考 [Docker rootless 前置条件](https://docs.docker.com/engine/security/rootless/)。

Systemd 已经安装，但不是 PID 1；再次安装不会启动服务管理器。要在容器内运行
systemd，需要管理员批准修改 Pod 启动方式和 cgroup 委派，而非安装软件包。
本流程不使用 `systemctl --user` 或 `loginctl`，直接运行 `dockerd-rootless.sh`。

为其他账号配置前，先检查账号 ID 和 subordinate 范围：

```bash
id
command -v dockerd-rootless.sh rootlesskit newuidmap newgidmap slirp4netns
awk -F: -v account="$(id -un)" '$1 == account' /etc/subuid /etc/subgid
```

已检查账号为 `jiangfayu`，UID `23739`、GID `1072`，subuid/subgid 均为
`524288:65536`。基础检查 `unshare --user --map-root-user true` 通过，后续
RootlessKit 检查也确认命名空间 ID 0 映射到账号，ID 1–65536 映射到 subordinate
范围，但没有运行工作负载。缺少 rootless 脚本时，请管理员
安装 `docker-ce-rootless-extras`；缺失 UID/GID 工具、范围或用户命名空间被阻止
也需要管理员检查，不要分配相互重叠的 ID。

用户已完成以下准备；2026-11-16 的检查确认 `slirp4netns` 1.3.3 已安装，两个
目录所有者均为 `23739:1072`，权限均为 `0700`。数字 ID 仅适用于当前账号：

```bash
sudo dnf install slirp4netns

sudo install -d -m 0700 -o 23739 -g 1072 \
  /run/user/23739 \
  /var/tmp/jiangfayu-docker-rootless
```

无需每次启动应用都重复准备。工作区替换后，如目录缺失，请管理员重新创建并
核对账号 ID。运行时目录必须为用户独占、非 NFS，工作区关闭/替换时应删除并
重新创建，不要放在 `/tmp` 下。这里 `/run/user/23739` 位于工作区 overlay，
并非 systemd 管理的 tmpfs；获准的工作区启动/清理机制需要管理其生命周期。
`/var/tmp` 数据目录也位于该 overlay，属于可丢弃存储。

### 不用 sudo 或 systemd 启动 rootless Docker

启动前检查已有守护进程与两种可能的 socket：

```bash
ps -C dockerd -o pid=,comm=
ls -ld /run/user/23739 /var/tmp/jiangfayu-docker-rootless
ls -l /run/user/23739/docker.sock /var/run/docker.sock
```

停止时没有 socket 属于预期情况。2026-11-16 检查时没有运行中的 `dockerd`，
root socket 也不存在。如果已有守护进程，先确定其端点，不要直接启动另一个。
Rootless 引擎的镜像、容器和卷与此前 root 引擎的 `/var/lib/docker` 相互独立。
不要复制或迁移旧存储、删除 socket，也不要为权限错误启动重复守护进程。

以下命令曾以 `jiangfayu` 身份运行，在网络初始化阶段失败。保留为记录，
当前测试已停止：

```bash
export XDG_RUNTIME_DIR=/run/user/23739

dockerd-rootless.sh \
  --data-root=/var/tmp/jiangfayu-docker-rootless
```

命令以前台方式输出日志。显式数据根目录避免默认
`$HOME/.local/share/docker` 落到 NFS 上。先检查已有
`${XDG_CONFIG_HOME:-$HOME/.config}/docker/daemon.json`，不要在配置文件和
命令行重复设置 `data-root`。不要对已有数据随意切换存储驱动，也不要自动改回
`sudo dockerd`。参考
[Docker 无 systemd 启动说明](https://docs.docker.com/engine/security/rootless/tips/)。

如需断开 SSH 后继续运行，先创建 `tmux new-session -s inspirehep-docker`，
在其中运行守护进程命令。按 `Ctrl+B`、再按 `d` 分离，用
`tmux attach-session -t inspirehep-docker` 重新连接。应用重启时保持守护进程运行。
Tmux 不能跨工作区替换存活，自动恢复需管理员批准的工作区启动/进程管理配置。

### 每个客户端终端显式选择 rootless socket

每个运行 Docker、Compose 或 Make 的终端/tmux 窗口都先执行以下配置；
前台守护进程不会替其他 shell 设置环境变量：

```bash
unset DOCKER_CONTEXT
export XDG_RUNTIME_DIR=/run/user/23739
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/docker.sock"

docker version
docker compose version
docker info
docker info --format '{{.DockerRootDir}}'
docker info --format '{{json .SecurityOptions}}'
```

预期 Docker Root Dir 为 `/var/tmp/jiangfayu-docker-rootless`，Security Options
含 `rootless`。清除 `DOCKER_CONTEXT`，避免它覆盖 `DOCKER_HOST`。本流程不依赖
默认 root socket `/var/run/docker.sock` 或 `newgrp docker`。Rootless socket
不存在时检查启动是否成功、端点是否正确；权限错误时检查目录/socket 所有权及
当前账号。不要将 socket 改成所有人可写。

守护进程可连接后，测试基础容器：

```bash
docker run --rm hello-world
```

该命令会下载并运行镜像，文档更新时没有执行。通过只能证明基础工作负载可用，
不能证明镜像构建、绑定挂载、端口发布或完整 Compose 栈可用，导入数据前应分别
验证。在守护进程终端按 `Ctrl+C` 会停止引擎并影响工作负载。

### 嵌套 Docker 的前置条件与错误处理

当前 `/sys/fs/cgroup` 是只读的 cgroup v2 挂载。PID 1 的能力集中包含
`CAP_SYS_ADMIN` 与 `CAP_NET_ADMIN`，但这不证明所有内部容器操作可用。
守护进程可能成功启动，而工作负载在创建 cgroup、挂载或桥接网络时失败。

没有 systemd 及 cgroup 委派时，rootless Docker 不提供通常的 `--cpus`、
`--memory`、`--pids-limit` cgroup 限制，不能假定 Compose 资源限制生效；
外层 Pod 的限制仍约束工作区。Slirp4netns/RootlessKit 提供用户态网络，应从原生
应用及 Pod 外部分别检查发布端口。Rootless 不会创建 Kubernetes Service，也
不会绕过 NetworkPolicy。参考
[Docker rootless 资源限制](https://docs.docker.com/engine/security/rootless/tips/#limiting-resources)。

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

### 存储：已验证挂载、rootless 引擎与持久化数据

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
| `/run/user/23739` | 容器 overlay，私有运行时目录 | Rootless Docker socket 与运行时状态，替换后需重新创建 |
| `/var/tmp/jiangfayu-docker-rootless` | 同一容器 overlay，选定的 rootless 数据根目录 | 可丢弃引擎数据与默认卷 |
| `/var/lib/docker` | 同一容器 overlay，原 root 引擎存储 | 与 rootless Docker 独立，无 Pod 级持久化保证 |
| `/gfs`、`/gfs/jiangfayu` | 上次检查为容器 overlay，无独立挂载 | 不提供额外容量或持久化，配置挂载后应重新检查 |

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
Docker 或 Podman 可用的引擎存储文件系统。

数据库 dump、导入 JSON 和备份可以存放在 NFS，例如拟议目录
`/aifs/user/data/jiangfayu/inspirehep-data/backups/`。检查备份命令结果并测试恢复，
使用数据库专用备份工具；复制正在运行的 PostgreSQL 数据目录不能替代正确的
备份流程。文档更新没有创建该示例目录。

#### Rootless Docker 存储与应用数据是不同问题

引擎数据根目录不能使用 NFS，包括当前 NFS home。选定的
`/var/tmp/jiangfayu-docker-rootless` 是私有非 NFS 路径，但 2026-11-16 的
内核 overlay 检查表明它不能用作嵌套 overlay upper 目录。`fuse-overlayfs` 未
安装；开发账号能打开 `/dev/fuse`，但没有测试 FUSE 挂载或引擎。安装建议提出后
用户决定停止测试，不能把该方案写成已验证修复。Docker 客户端/守护
进程配置可留在 NFS home，容器层、镜像和默认卷不能使用 NFS 默认数据根目录。

本地引擎存储不等于应用数据持久化，内部命名卷会随数据根目录丢失；服务绑定
挂载需要独立、获准的持久化文件系统，PostgreSQL 的 NFS `soft` 限制仍适用。
容器 UID 0 映射到开发账号，其他容器 UID 映射到 subordinate ID，需按实际镜像
用户及 PVC 检查权限。NFS 源码绑定挂载可能遇到 UID/GID 不匹配或所有权限制，
尤其是完整 Docker 应用工作流；不要通过递归 chown 共享源码目录来绕过问题。

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
   firewalld 不等于没有这些规则。RootlessKit/slirp4netns 负责 rootless 端口
   发布与用户态网络，需要单独检查；此前 root 引擎也可能设置了转发/NAT 规则。
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

## 9. 实际测试结果与阻碍（2026-11-16）

以下为代理沙箱外真实工作区的检查结果，不代表安装成功。用户已要求停止后续
测试，将改用其他机器。测试没有留下运行中的 Docker 或 INSPIRE 服务，没有
初始化数据库、重置 fixtures、上传到发布商/INSPIRE、发送邮件或启用采集计划。
代理没有修改系统软件包或 Pod/节点设置。

| 检查 | 结果与含义 |
| --- | --- |
| Pod 实际资源 | `cpu.max=1600000 100000`，即 16 CPU 配额；`memory.max=34359738368`，即 32 GiB。约 8 GiB 已使用，未记录 OOM。主机可见 256 CPU / 约 503 GiB 并非 Pod 配额。容量适合初期小规模测试的判断，不等于完整栈基准测试或浏览器/索引并发保证。 |
| 内核与用户命名空间 | `vm.max_map_count=262144`；RootlessKit 3.3.0 成功建立配置的 UID/GID 映射。Systemd 已安装但 PID 1 仍为 `bash`，cgroup v2 只读。 |
| Rootless Docker 启动 | 文档中的 `dockerd-rootless.sh --data-root=...` 以退出码 `1` 失败：slirp4netns 创建 `tap0` 时返回 `open: No such file or directory`。`/dev/net` 和 `/dev/net/tun` 不存在；`/proc/misc` 和 `/sys/class/misc/tun/dev` 中未看到 TUN 注册。节点驱动及 Pod 设备访问需管理员检查，未产生可用 daemon/socket。 |
| 嵌套 overlay 存储 | 独立 RootlessKit `--net=none` 检查在准备目录下尝试临时 overlay 挂载，退出码 `32`，错误为 `overlay: filesystem on .../upper not supported as upperdir`。这是已测试内核 overlay 配置的独立存储阻碍，不能推广为所有驱动都失败。临时检查文件已清理。 |
| FUSE 候选 | 开发账号成功打开 `/dev/fuse`，但 `fuse-overlayfs` 未安装，也没有测试。软件包可安装并不证明容器兼容或持久化。 |
| Podman | 未安装或运行。无守护进程设计不能证明当前网络、存储、cgroup 或 Compose 兼容性；既不宣称成功，也不宣称必然失败。 |
| Compose 配置 | `docker compose -f docker-compose.yml -f docker-compose.override.yml config --quiet` 退出 `0`，提示 `FERNET_KEY` 与 `AIRFLOW_UID` 未设置。解析配置不代表容器或 Airflow 就绪。 |
| 本地 INSPIRE | `127.0.0.1` 的 3000、8000、8001、8080、5432、5434、5672、6379、9200、9000 端口检查均关闭。所查位置/PATH 中缺少 backend/backoffice `.venv`、`.env`、UI `node_modules`、Poetry、Node 和 Yarn。没有可供采集测试的运行中本地实例。 |
| 存储 | 两个 `/aifs` 仍为 NFSv4 `soft`；`/gfs` 仍为工作区 overlay，没有独立挂载。overlay 当时约 786 GiB 可用，数据 NFS 约 1.95 TiB 可用，属于共享、动态容量，不是配额或持久性保证。没有配置持久化服务卷。 |
| 调度 | 未发现 `cron`/`crond` 进程，未启用或修改计划。 |

### 已迁移采集脚本

已阅读关联会话 **Check migration status** 和
`../ihep-harvest-scripts/docs/IHEP-DEPLOYMENT.md`。该项目继续使用已有 uv / Python
3.14 环境，与本仓库的 Poetry / Python 3.11 分开。以下命令已在其目录运行：

```bash
cd ../ihep-harvest-scripts
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR=/tmp/inspire-ihep-readiness-uv-cache \
  sh scripts/run-job.sh --check
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR=/tmp/inspire-ihep-readiness-uv-cache \
  uv run --locked --extra retinspire --no-sync pytest -q \
  -p no:cacheprovider --basetemp=/tmp/inspire-ihep-pytest
```

就绪检查退出 `1`，仅报告缺少 `external/bibclassify/bibclassify_cli.py`。
离线套件 **70 个测试及 4 个子测试通过**，11 条警告，耗时 7.20 秒。覆盖解析、
转换/schema 验证，以及模拟的 API/邮件/feed 交互，不证明发布商到本地 INSPIRE
的真实集成。检查后关联仓库没有已跟踪文件变更。

源码检查还发现引擎启动以外的集成工作：

- `lib/inspirelabslib3.py` 仍将查询 API 固定为生产
  `https://inspirehep.net/api`；真实测试前需明确选择本地端点和本地认证，不能
  假设已有生产 token 适用于本地实例。
- `lib/start_retinspire3json.py` 仍打印指向 DESY 命名 CERN S3 桶的上传交接命令。
  没有执行这些命令；本地输入/输出桶与上传交接尚未实现或验证。
- 本仓库 `workflows/dags/literature/desy_harvest.py` 通过 S3 消费 JSONL/PDF，
  创建 backoffice `HEP_PUBLISHER_CREATE` 工作流，再由 backoffice 初始化触发
  Airflow。验证该发布商路径需要 backoffice worker、Airflow、本地连接及桶，
  超出原生 UI/API 启动范围。还需验证所选拓扑的 `host.docker.internal` 路由和
  其他工作流依赖。
- 受控元数据导入及索引/搜索/PDF 检查可覆盖较小路径，但不能替代发布商摄取
  验证；本次没有执行导入或生产提交。

### 测试与未来备份适用性

从资源容量判断，当前 CPU/RAM 可以尝试初期有限规模部署，但本工作区**尚未
就绪**：网络与已测存储配置阻止 rootless Docker，应用未安装/运行，采集集成
未完成，Podman 未测试。用户已选择其他机器，不要为了记录结果继续处理此前
管理员请求。

未来机器需具备可用引擎、受支持的非 NFS 引擎存储、明确持久化服务挂载，以及
受管理的启动/调度机制。在 Kubernetes 中需集群管理员配置设备和持久卷等资源；
普通机器也需验证自身服务/存储环境。不要直接复制本 Pod 的数字账号 ID 或假设
目录布局相同。

运行副本本身不是备份。应保留原始 JSONL/XML、PDF、去重状态、数据库 dump 及
恢复所需配置，具备独立保留副本并验证恢复。现有采集清理包含 PDF 180 天策略，
将工作目录视为档案前需调整。NFS 可按站点策略保存经验证的导出/备份文件，
但当前 `soft` 挂载不能承载 PostgreSQL 运行数据。可丢弃 overlay 卷不应作为
唯一保留副本。没有记录/PDF 规模、增长、保留及恢复要求，不能证明完整镜像容量
足够。本次未测试备份或恢复。

## 参考与验证范围

- [AlmaLinux 仓库与 CRB](https://wiki.almalinux.org/repos/AlmaLinux)
- [RHEL 10 包清单（含 libpq-devel）](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/pdf/package_manifest/Red_Hat_Enterprise_Linux-10-Package_manifest-en-US.pdf)
- [Docker RHEL 安装文档](https://docs.docker.com/engine/install/rhel/)
- [OpenSearch Docker 前置条件](https://docs.opensearch.org/3.9/install-and-configure/install-opensearch/docker/)
- [Docker rootless 前置条件](https://docs.docker.com/engine/security/rootless/)
- [Rootless Docker 无 systemd 启动、存储与资源限制](https://docs.docker.com/engine/security/rootless/tips/)
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

2026-11-16 的只读检查确认用户已完成 rootless 准备：`slirp4netns` 已安装，
两个准备目录的所有权及权限正确。当时没有运行中的 Docker 守护进程。
Systemd 已安装，但 PID 1 仍为 `bash`，cgroup v2 仍只读；当前启动状态以上述
结果为准，而非此前 root 守护进程运行中的历史观察。

后续实际启动尝试及存储检查见第 9 节。Rootless 守护进程启动失败；
`hello-world`、Compose 工作负载、应用安装/测试、需要权限的防火墙规则列表、
集群外部访问及备份恢复仍未验证。采集离线套件通过和 Compose 配置解析成功
不能证明真实集成，运行测试已按用户要求停止。
