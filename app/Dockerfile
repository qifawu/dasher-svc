# =============================================================================
# Dockerfile —— dasher-svc 多阶段构建
#
#   deps 阶段：只装生产依赖（不带 devDependencies，镜像更小）
#   运行阶段：极小的 node:alpine，非 root 用户跑进程
#
#   BUILD_TAG / GIT_SHA 由 CI 的 `docker build --build-arg` 传入
#   （对应课程 Workflow-Docker-Build-and-Test 一课），落到 ENV 后
#   server.js 用它们拼 /api/version 的响应 —— 这就是"制品可追溯"的实现方式：
#   镜像里天然带着自己是哪次构建、哪个 git commit 打出来的。
# =============================================================================

# ---- deps 阶段：装生产依赖 ----
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json ./
# 仓库里没有带 package-lock.json（只有 express 一个主流依赖，写进 package.json 即可），
# 所以这里用 npm install 而不是 npm ci；真实生产项目建议提交 lockfile 后改用 npm ci。
RUN npm install --omit=dev

# ---- 运行阶段 ----
FROM node:20-alpine
WORKDIR /app

ARG BUILD_TAG=dev
ARG GIT_SHA=unknown
ENV APP_TAG=$BUILD_TAG \
    APP_SHA=$GIT_SHA \
    NODE_ENV=production

COPY --from=deps /app/node_modules ./node_modules
COPY server.js package.json ./

# node:20-alpine 自带一个非特权的 "node" 用户（uid 1000）——
# 用它跑进程而不是默认的 root，是常见的容器安全加固点（Security Guide 一章的精神延伸到镜像层面）。
USER node

EXPOSE 8000
CMD ["node", "server.js"]
