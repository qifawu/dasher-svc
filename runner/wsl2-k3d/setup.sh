#!/usr/bin/env bash
# =============================================================================
# setup.sh —— 在 WSL2 Ubuntu 里搭好本大实验要用的本地环境：
#   docker + k3d(集群名 gitops，映射 NodePort 30081/30082) + kubectl + node
#   + 一个 GitHub Actions 自建 runner（用来做 verify-dev/verify-prod 的只读冒烟）
#
# 跟 labs/jenkins/wsl2-k3d/setup.sh 是同一套底座（Windows 11 Home 无 Hyper-V，
# WSL2 原生可用），如果你已经跑过那个脚本，docker/kubectl 这些会直接跳过重装。
#
# 用法（WSL Ubuntu 终端里）:
#   cd /mnt/c/Users/<你>/cc-ai-project/kodekloud-notes-and-labs/labs/github-actions/runner/wsl2-k3d
#   bash setup.sh
#
# 幂等：可重复跑。若提示要开 systemd：PowerShell 里 `wsl --shutdown` 后重进再跑一次。
#
# ⚠️ k3d 集群名固定叫 "gitops"——ArgoCD 大实验也会装到这个集群的 argocd namespace，
#    两个大实验共享同一个集群，别改名字，也别在这个脚本里瞎删集群（teardown.sh 默认不删集群）。
#
# 联网下载来源（都是官方/主流，跟 Jenkins 大实验的 setup.sh 同一风格，仅在本 WSL 内运行）：
#   - apt 官方源：docker.io / curl / jq
#   - Node.js 20：deb.nodesource.com（NodeSource 官方源，Ubuntu 默认仓库版本太旧）
#   - kubectl：dl.k8s.io（Kubernetes 官方）
#   - k3d：官方安装器 raw.githubusercontent.com/k3d-io/k3d（CNCF 生态）
#   - GitHub Actions 自建 runner：github.com/actions/runner 官方 release
# =============================================================================
set -euo pipefail

CLUSTER=gitops
DEV_PORT=30081
PROD_PORT=30082
RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/actions-runner"
RUNNER_VERSION="2.335.1"   # 需要更新版本时去 https://github.com/actions/runner/releases 查最新 tag
                            # (runner 首次连上 GitHub 后也会自动更新到最新版，这里只影响首次下载)

# ---- 0) systemd 检查（docker 服务要跑起来需要）----
if ! systemctl is-system-running >/dev/null 2>&1 && [ "$(ps -p 1 -o comm=)" != "systemd" ]; then
  echo "[!] 这个 WSL 还没启用 systemd。正在写 /etc/wsl.conf ..."
  sudo tee /etc/wsl.conf >/dev/null <<'EOF'
[boot]
systemd=true
EOF
  echo ""
  echo ">>> 请在 Windows 的 PowerShell 里执行：  wsl --shutdown"
  echo ">>> 然后重新打开 Ubuntu，再跑一次 bash setup.sh"
  exit 0
fi

echo "==> [1/6] apt 装基础组件（docker/curl/jq）..."
sudo apt-get update -y
sudo apt-get install -y docker.io curl jq ca-certificates git

echo "    装 Node.js 20（NodeSource 官方源，Ubuntu 22.04 默认仓库的 nodejs 是 12.x，
    跑不动 app/ 要求的 >=18 和 'node --test'，实测踩过这个坑，已换源）..."
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 18 ]; then
  # Ubuntu 自带的 nodejs/npm 会连带装 libnode-dev，跟 NodeSource 的 nodejs 包
  # 抢同一批 /usr/include/node/* 头文件，装之前必须先清掉，否则 dpkg unpack 冲突报错
  # （实测踩过：'trying to overwrite .../common.gypi, which is also in package libnode-dev'）。
  sudo apt-get purge -y nodejs npm libnode-dev libnode72 nodejs-doc 2>/dev/null || true
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi

echo "==> [2/6] 启动 docker，把当前用户加进 docker 组..."
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER" || true

echo "==> [3/6] 装 kubectl（Kubernetes 官方二进制，已装过就跳过）..."
if ! command -v kubectl >/dev/null 2>&1; then
  KUBE_VER="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
  curl -LO "https://dl.k8s.io/release/${KUBE_VER}/bin/linux/amd64/kubectl"
  sudo install -m 0755 kubectl /usr/local/bin/kubectl && rm -f kubectl
fi

echo "==> [4/6] 装 k3d（官方安装器，已装过就跳过）..."
if ! command -v k3d >/dev/null 2>&1; then
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | sudo bash
fi

echo "==> [5/6] 创建 k3d 集群 '${CLUSTER}'（映射 dev:${DEV_PORT} / prod:${PROD_PORT} 到 localhost）..."
if ! sudo k3d cluster list 2>/dev/null | grep -q "^${CLUSTER}"; then
  sg docker -c "k3d cluster create ${CLUSTER} \
      -p \"${DEV_PORT}:${DEV_PORT}@server:0\" \
      -p \"${PROD_PORT}:${PROD_PORT}@server:0\" \
      --wait" \
    || k3d cluster create ${CLUSTER} \
      -p "${DEV_PORT}:${DEV_PORT}@server:0" \
      -p "${PROD_PORT}:${PROD_PORT}@server:0" \
      --wait
else
  echo "    集群 '${CLUSTER}' 已存在，跳过创建（可能是之前跑 ArgoCD 大实验时建的，复用即可）。"
fi

echo "    预建 dasher-dev / dasher-prod 两个 namespace（ArgoCD 同步时也会用到，提前建不冲突）..."
kubectl create namespace dasher-dev  --dry-run=client -o yaml | kubectl apply -f - || true
kubectl create namespace dasher-prod --dry-run=client -o yaml | kubectl apply -f - || true

echo "==> [6/6] 下载 GitHub Actions 自建 runner（官方 release，已下载就跳过）..."
if [ ! -d "${RUNNER_DIR}" ]; then
  mkdir -p "${RUNNER_DIR}"
  (
    cd "${RUNNER_DIR}"
    curl -L -o actions-runner-linux-x64.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
    tar xzf actions-runner-linux-x64.tar.gz
    rm -f actions-runner-linux-x64.tar.gz
  )
else
  echo "    ${RUNNER_DIR} 已存在，跳过下载。"
fi

echo ""
echo "============================================================"
echo " 集群 + runner 二进制就绪！"
echo "------------------------------------------------------------"
echo " 自检：kubectl get nodes ; k3d cluster list ; kubectl get ns"
echo ""
echo " ⚠️ 剩下这步没法脚本化，需要你手动做一次（GitHub 不允许脚本拿到注册 token）："
echo "   1. 打开你的 dasher-svc 仓库 → Settings → Actions → Runners → New self-hosted runner"
echo "   2. 选 Linux / x64，复制页面上的 token"
echo "   3. 回到这台机器： cd ${RUNNER_DIR}"
echo "      ./config.sh --url https://github.com/<OWNER>/<REPO> \\"
echo "                  --token <粘贴刚才复制的 token> \\"
echo "                  --labels wsl2-k3d --name wsl2-k3d-runner --unattended"
echo "      （--labels wsl2-k3d 是关键：workflow 里 runs-on: [self-hosted, wsl2-k3d] 要靠它匹配到这台 runner）"
echo "   4. 装成系统服务，这样关终端/重启 WSL 也不用手动重启 runner："
echo "      sudo ./svc.sh install && sudo ./svc.sh start"
echo "      （不想装服务、只想临时跑一次也可以直接 ./run.sh 前台跑）"
echo "------------------------------------------------------------"
echo " 完成后去仓库 Settings → Actions → Runners 确认状态是 Online。"
echo " 清理：bash teardown.sh（默认不删共享的 k3d 集群，只停 runner）"
echo "============================================================"
