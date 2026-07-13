// =============================================================================
// server.js —— dasher-svc：GitHub Actions 大实验用的自包含小服务
//
//   呼应课程 Introduction 章节 "Meeting with Dasher Team" 的项目背景故事：
//   一个外卖平台的订单服务。用纯 Express + 标准库写法，方便在任何 runner 上
//   npm install / npm test / docker build，不需要数据库等外部依赖。
//
// 路由:
//   GET /             首页，纯文本欢迎
//   GET /healthz      健康检查，200 "ok"（自建 runner 冒烟验证也用它探活）
//   GET /api/version  {"version":"<tag>","sha":"<git短sha>"}
//                      —— tag/sha 由 Docker 构建时 --build-arg 注入，
//                         CD 流水线拿它断言"线上版本 == 本次构建"
//   GET /api/orders   假订单列表（呼应 Dasher 外卖/订单场景）
// =============================================================================
'use strict';

const express = require('express');

const PORT = process.env.PORT || 8000;
// APP_TAG / APP_SHA 由 Dockerfile 里的 ARG BUILD_TAG / ARG GIT_SHA 通过 ENV 注入，
// 本地直接 node server.js 跑（没走 Docker）时用 dev/unknown 兜底。
const APP_TAG = process.env.APP_TAG || 'dev';
const APP_SHA = process.env.APP_SHA || 'unknown';

const app = express();

function seedOrders() {
  return [
    { id: 1, item: 'Kung Pao Chicken', dasher: 'Alex', status: 'delivered' },
    { id: 2, item: 'Margherita Pizza', dasher: 'Sam', status: 'in_transit' },
    { id: 3, item: 'Veggie Burrito Bowl', dasher: 'Priya', status: 'preparing' },
  ];
}

app.get('/', (req, res) => {
  res
    .type('text/plain')
    .send(`dasher-svc ${APP_TAG} — try /healthz, /api/version, /api/orders\n`);
});

app.get('/healthz', (req, res) => {
  res.status(200).send('ok');
});

app.get('/api/version', (req, res) => {
  res.json({ version: APP_TAG, sha: APP_SHA });
});

app.get('/api/orders', (req, res) => {
  res.json(seedOrders());
});

// 导出 app 给单测用（node:test 里起临时端口打请求，不需要额外的测试框架）。
// require.main === module 判断：只有直接 `node server.js` 启动时才真的监听端口，
// 被 test 文件 require 进去时不会意外占用端口。
if (require.main === module) {
  app.listen(PORT, () => {
    console.log(`dasher-svc ${APP_TAG} (sha ${APP_SHA}) listening on :${PORT}`);
  });
}

module.exports = { app };
