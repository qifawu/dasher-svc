#!/usr/bin/env bash
# =============================================================================
# teardown.sh —— 收工脚本：停/卸载自建 runner。
#
# ⚠️ 默认【不删除】k3d 集群 'gitops'——它跟 ArgoCD 大实验共享同一个集群，
#    删早了会连带影响还没做完的 ArgoCD 实验。真要把集群也删掉，
#    确认两个大实验都做完了，加 --with-cluster 参数或看底部手动命令。
#
# 用法:
#   bash teardown.sh                # 只停 runner（推荐，日常收工用这个）
#   bash teardown.sh --with-cluster # 连 k3d 集群一起删（两个大实验都做完、要彻底清场才用）
# =============================================================================
set -euo pipefail

CLUSTER=gitops
RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/actions-runner"
WITH_CLUSTER=false
[ "${1:-}" = "--with-cluster" ] && WITH_CLUSTER=true

if [ -d "${RUNNER_DIR}" ]; then
  echo "==> 停 GitHub Actions 自建 runner ..."
  (
    cd "${RUNNER_DIR}"
    if [ -f svc.sh ] && sudo ./svc.sh status >/dev/null 2>&1; then
      sudo ./svc.sh stop || true
      sudo ./svc.sh uninstall || true
      echo "    已停止并卸载 runner 系统服务。"
    else
      echo "    没检测到 runner 服务（可能是用 ./run.sh 前台跑的，Ctrl+C 手动停就行）。"
    fi
  )
  echo "    提醒：runner 在 GitHub 那边的注册记录不会自动消失，"
  echo "          要彻底清掉去仓库 Settings → Actions → Runners 里手动 Remove。"
else
  echo "==> 没找到 ${RUNNER_DIR}，跳过 runner 清理。"
fi

if [ "${WITH_CLUSTER}" = true ]; then
  echo "==> --with-cluster：删除共享 k3d 集群 '${CLUSTER}'（连 ArgoCD 大实验的东西也会一起没）..."
  k3d cluster delete "${CLUSTER}" 2>/dev/null || sudo k3d cluster delete "${CLUSTER}" 2>/dev/null || true
  echo "    集群已删除。"
else
  echo "==> 保留 k3d 集群 '${CLUSTER}'（ArgoCD 大实验可能还在用）。"
  echo "    真要删：k3d cluster delete ${CLUSTER}"
fi

echo "==> 收工完成。"
