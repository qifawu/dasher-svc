# 🧪 GitHub Actions CI/CD 融会贯通大实验 · 项目概览

贴近生产的 CI/CD 流水线：**dasher-svc**（Node.js/Express 外卖订单服务，呼应课程
"Meeting with Dasher Team" 的项目背景）从 push 代码到 GHCR 镜像、到 GitOps 配置仓库改 tag、
到自建 runner 冒烟验证、到 prod 人工审批——一条龙走完 GitHub Actions 这门课几乎所有核心章节。

**两份文档分工**：
- **`HANDS-ON.md`** —— 从零**手写**这条流水线的完整教程（面试导向）：逐 key 讲 YAML、
  怎么找对 action、自建 runner 专章、安全加固、**七个真实踩坑实录**、面试问答 15 题 + 验收清单。
  想把这个项目讲进面试，看这份。
- **`lab-ops.md`** —— 按课程章节顺序的**操作合集**（也是推进 Notion 的那份）。

详细操作步骤看 **`lab-ops.md`**（按课程章节编号，跟 `labs/jenkins/lab-ops.md` 同一种写法）。
本页只讲结构和"为什么这么设计"。

## ⚠️ 这门课的 CD 边界（贯穿全实验的核心设计原则）

**本实验的 CD 只做到"把新镜像 tag 改进一个独立的 GitOps 配置仓库并 commit+push"为止。**
全程没有任何一处出现 `kubectl apply` / `kubectl set image`。真正把这个 tag 变成集群里跑着的
Pod，是另一条腿的事——**ArgoCD 持续监听那个 GitOps 仓库，自动 sync 到集群**（那是
`labs/argocd/` 大实验的地盘，另一位 agent 在设计，两个实验拼起来才是完整的部署闭环）。

这个边界不是偷懒，是真实生产里 GitOps 模式的标准做法：**CI 流水线不该有 kubectl 权限**，
唯一的部署入口是 Git（GitOps 仓库），谁改了 Git 谁就有审计记录，ArgoCD 只信 Git 里的状态、
不信任何流水线临时拼出来的命令。这个区分本身就是本实验最大的面试考点。

那自建 Runner（Self-Hosted Runner 那一章）派上什么用场？GitHub 云端服务器连不到你本机内网，
但要验证"部署有没有真的生效"就得连到本机 WSL2 里的 k3d 集群——所以自建 runner 只做
**部署后的只读冒烟验证**（`curl .../api/version` 断言线上 tag == 本次构建 tag），
不是用它来做部署本身。

## 目录结构

```
labs/github-actions/
├── app/                          # dasher-svc 源码
│   ├── server.js                 # Express：/ /healthz /api/version /api/orders
│   ├── package.json
│   ├── Dockerfile                # 多阶段构建，ARG BUILD_TAG/GIT_SHA 注入版本
│   └── test/server.test.js       # node:test 单测，CI 门禁靠它
├── .github/
│   ├── workflows/
│   │   ├── ci-cd.yml             # 主流水线：test → build-push → GitOps dev → 冒烟
│   │   │                         #   → GitOps prod(人工审批) → 冒烟 → 报告
│   │   ├── notify-slack.yml      # 可复用 workflow（workflow_call），报告结果
│   │   └── security.yml          # CodeQL 静态扫描
│   └── actions/
│       └── bump-gitops-tag/      # composite action：改 GitOps 仓库 tag 并 push
├── runner/wsl2-k3d/              # 自建 runner + 本地 k3d 集群 'gitops' 的搭建脚本
│   ├── setup.sh / teardown.sh
│   └── README.md
├── network-policies/             # 【原 CKA 大实验并入】隔离 dasher-dev↔dasher-prod（第 13 节）
│   ├── dasher-prod-default-deny.yaml
│   ├── dasher-prod-allow-same-ns-and-external.yaml   # 放行同命名空间 + 外部(保住 NodePort 冒烟验证)
│   └── dasher-prod-allow-dns-egress.yaml
├── faults/                       # 【原 CKA 大实验并入】部署故障注入排障（第 14 节）
│   ├── README.md / inject.sh / solutions.md
│   └── fixtures/                 #   PVC Pending / Pod Pending / broken-kubeconfig 三个故障夹具
├── HANDS-ON.md                   # 从零手写流水线的完整教程（面试导向）
├── lab-ops.md                    # 操作合集（照课程章节顺序编号）
└── README.md                     # 本文件
```

## 应用隔离与部署排障（第 13–14 节，原独立 CKA 大实验并入）

CI/CD 把版本推上 `dasher-dev`/`dasher-prod` 之后，"应用侧"的集群运维也贴着这条流水线走：
**第 13 节** 用 NetworkPolicy 给两个命名空间做东西向隔离（关键约束是**不能打断第 8/9 节自建 runner
的 NodePort 冒烟 curl**）；**第 14 节** 注入 4 类高频部署故障练排障。两节都在 `lab-ops.md` 末尾。
注意故障 1/2 跨 lab 依赖 `labs/argocd/cluster-rbac/`（RBAC 凭证）和 `labs/cluster-ops/upgrade-drill/`
（worker 节点），脚本里已用相对路径指过去。纯集群生命周期运维另见 `labs/cluster-ops/`。

## 跟 Jenkins 大实验的关键差异（不是偷懒，是 GitHub Actions 本身的限制）

Jenkins 大实验里 `Jenkinsfile` 放在仓库任意路径都行，因为 Jenkins Pipeline 任务在 UI 里配了
`Script Path=labs/jenkins/Jenkinsfile`，Jenkins 会自己去那个路径找。**GitHub Actions 没有等价的
"workflow 路径"设置**——workflow 文件必须在被监听仓库的**真实根目录** `.github/workflows/` 下，
没法指定"去某个子目录找"。

所以这个目录（`labs/github-actions/`）在设计上就是**要被推送成一个独立 GitHub 仓库的内容**
（即：新建一个 GitHub 仓库，比如叫 `dasher-svc`，把这个目录下的所有文件当作那个仓库的根目录推上去），
而不是留在 `cc-ai-project` 这个 monorepo 里指望 GitHub 去子目录找 workflow。这也是为什么它需要自己的
GHCR 权限、自己的 Environments、自己的自建 runner 注册——这些都是"仓库级"的能力，天然要求它是一个
独立仓库。`lab-ops.md` 第 1 步会讲怎么推。

## 跨仓库契约（给自己和 ArgoCD 大实验对齐用，改了这里记得同步通知）

| 项 | 值 |
|---|---|
| 应用名 | `dasher-svc`，Node.js/Express，端口 `8000` |
| 镜像 | `ghcr.io/<OWNER>/dasher-svc`，tag = `<run_number>-<git短7位sha>` |
| GitOps 仓库 | 独立远程仓库，owner/repo 存在仓库级 secret `GITOPS_REPO`；push 权限的 PAT 存在 `GITOPS_PAT` |
| GitOps 仓库结构 | Kustomize：`overlays/dev/kustomization.yaml`、`overlays/prod/kustomization.yaml`，`images:` transformer 指定 `dasher-svc` 的 tag |
| k3d 集群 | 固定名字 `gitops`（ArgoCD 也装在这个集群的 `argocd` namespace） |
| 目标 namespace | `dasher-dev`（NodePort `30081`）、`dasher-prod`（NodePort `30082`） |
| 自建 runner 标签 | `wsl2-k3d`（`runs-on: [self-hosted, wsl2-k3d]`） |
| 路由契约 | `GET /`、`GET /healthz`→200 "ok"、`GET /api/version`→`{"version","sha"}`、`GET /api/orders`→假订单列表 |
