# WSL2 + k3d + 自建 runner（Windows 11 Home 专用起法）

跟 `labs/jenkins/wsl2-k3d/README.md` 同一条路：**Windows 11 Home 无 Hyper-V，Multipass 跑不了**，
用 WSL2（Home 原生支持）在一个 Ubuntu 里跑 docker + 真 Kubernetes(k3d) + GitHub Actions 自建 runner。

如果你已经为 Jenkins 大实验装过 WSL2/docker/kubectl，这些步骤会自动跳过，直接复用。

## 一次性准备（Windows 侧，PowerShell 管理员，装过就跳过）

```powershell
wsl --install            # 装 WSL2 + 默认 Ubuntu（首次要重启）
```

## 起环境（Ubuntu 终端里）

```bash
cd /mnt/c/Users/<你的用户名>/cc-ai-project/kodekloud-notes-and-labs/labs/github-actions/runner/wsl2-k3d
bash setup.sh
```

脚本会：

1. 装 docker + kubectl + k3d + node（apt 官方源 / Kubernetes 官方 / k3d 官方安装器）
2. 建 k3d 集群 `gitops`（跟 ArgoCD 大实验共享同一个集群，映射 NodePort `30081`(dev) / `30082`(prod) 到 localhost）
3. 预建 `dasher-dev` / `dasher-prod` 两个 namespace
4. 下载 GitHub Actions 官方 runner 二进制到 `actions-runner/`

## 手动这一步：注册 runner（没法脚本化）

GitHub 不允许脚本直接拿到 runner 注册 token，必须去网页复制：

1. 打开你的 dasher-svc 仓库 → **Settings → Actions → Runners → New self-hosted runner**
2. 选 **Linux / x64**，复制页面给的 token
3. 回终端：

```bash
cd actions-runner
./config.sh --url https://github.com/<OWNER>/<REPO> \
            --token <粘贴 token> \
            --labels wsl2-k3d --name wsl2-k3d-runner --unattended

# 装成系统服务，重启 WSL / 关终端都不用管它
sudo ./svc.sh install
sudo ./svc.sh start
```

`--labels wsl2-k3d` 是关键：`ci-cd.yml` 里 `runs-on: [self-hosted, wsl2-k3d]` 要靠这个标签
把 job 精确路由到这台机器（而不是随便一台自建 runner）。

## 验证

- 仓库 Settings → Actions → Runners：状态变成 **Online**
- 推一次代码触发 `ci-cd.yml`，`verify-dev` / `verify-prod` 两个 job 应该跑在这台 runner 上
  （Actions 页面 job 详情会显示 "Running on wsl2-k3d-runner"）

## 会联网下载什么（都在 WSL 内，不碰 Windows 主机）

apt 官方源、NodeSource 官方 Node.js 20 源（Ubuntu 默认仓库的 nodejs 是 12.x，跑不动
`app/` 要求的 `>=18`，已改用 NodeSource）、Kubernetes 官方 kubectl、k3d 官方安装器、
GitHub 官方 actions/runner release、`bump-gitops-tag` composite action 里会额外装
`mikefarah/yq` 官方 release 二进制。均为主流可信来源。

## 清理

```bash
bash teardown.sh                # 日常收工：只停 runner，保留共享的 k3d 集群
bash teardown.sh --with-cluster # 两个大实验都做完了，要彻底清场才用这个
```

## 备选

同 Jenkins 大实验：如果以后升级到 Windows Pro / 装了 VirtualBox，
Multipass / Vagrant 双虚机版本也能等价搭出来，但比 WSL2 重，这里不主推。
