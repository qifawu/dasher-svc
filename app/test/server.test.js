// =============================================================================
// server.test.js —— CI "Unit Test" 阶段真正跑的单测
//
// 用 Node 内置 node:test + node:assert，不引入 jest/mocha 之类的重依赖
// （对应课程 Workflow-Configure-Unit-Testing 一课；node --test 是 Node 18+ 自带的
// 测试跑手，CI 里矩阵 node 18/20 两条腿都能直接用，无需额外装测试框架）。
//
// 用 node:http 起一个临时端口打真实 HTTP 请求，而不是 mock —— 这样如果谁把
// server.js 改坏（比如 /healthz 不再返回 "ok"），测试会真的红，CI 门禁才有意义。
// =============================================================================
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { app } = require('../server');

function startServer() {
  return new Promise((resolve) => {
    const server = app.listen(0, () => resolve(server)); // port 0 = 系统随机分配空闲端口
  });
}

function get(server, path) {
  const { port } = server.address();
  return new Promise((resolve, reject) => {
    http
      .get({ host: '127.0.0.1', port, path }, (res) => {
        let body = '';
        res.on('data', (chunk) => {
          body += chunk;
        });
        res.on('end', () => resolve({ status: res.statusCode, body }));
      })
      .on('error', reject);
  });
}

test('GET /healthz 返回 200 ok', async (t) => {
  const server = await startServer();
  t.after(() => server.close());

  const res = await get(server, '/healthz');
  assert.equal(res.status, 200);
  assert.equal(res.body, 'ok');
});

test('GET /api/version 返回 version + sha 字段', async (t) => {
  const server = await startServer();
  t.after(() => server.close());

  const res = await get(server, '/api/version');
  assert.equal(res.status, 200);
  const json = JSON.parse(res.body);
  assert.ok('version' in json, 'response 应该有 version 字段');
  assert.ok('sha' in json, 'response 应该有 sha 字段');
});

test('GET /api/orders 返回非空订单数组', async (t) => {
  const server = await startServer();
  t.after(() => server.close());

  const res = await get(server, '/api/orders');
  assert.equal(res.status, 200);
  const orders = JSON.parse(res.body);
  assert.ok(Array.isArray(orders));
  assert.ok(orders.length > 0);
  assert.ok('item' in orders[0]);
  assert.ok('status' in orders[0]);
});

test('GET / 返回文本欢迎语', async (t) => {
  const server = await startServer();
  t.after(() => server.close());

  const res = await get(server, '/');
  assert.equal(res.status, 200);
  assert.match(res.body, /dasher-svc/);
});
