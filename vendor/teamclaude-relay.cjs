#!/usr/bin/env node
// teamclaude-relay.cjs — тонкая HTTP-обёртка между Claude Code и teamclaude.
//
// Зачем: claude CLI в subscription-режиме НЕ передаёт x-api-key в запросах
// (только OAuth Bearer), а teamclaude ожидает x-api-key для авторизации
// proxy-клиента. Этот relay добавляет header к каждому проходящему запросу.
//
// Поток:  claude CLI → :PORT (этот) → :TC_PORT (teamclaude server)
//
// Env (все обязательные):
//   PROXY_API_KEY   — shared secret, должен совпадать с proxy.apiKey в teamclaude.json
//   TC_HOST         — host upstream teamclaude       (default 127.0.0.1)
//   TC_PORT         — port upstream teamclaude       (default 3456)
//   PORT            — port на котором слушает relay  (default 3457)
//
// Zero dependencies — только Node.js built-ins. Запускается под user openclaw
// через systemd (см. scripts/templates/teamclaude-relay.service).

'use strict';

const http = require('http');

const PORT = parseInt(process.env.PORT || '3457', 10);
const TC_HOST = process.env.TC_HOST || '127.0.0.1';
const TC_PORT = parseInt(process.env.TC_PORT || '3456', 10);
const PROXY_API_KEY = process.env.PROXY_API_KEY;

if (!PROXY_API_KEY) {
  console.error('[relay] FATAL: PROXY_API_KEY env var required');
  process.exit(1);
}

const server = http.createServer((req, res) => {
  const headers = { ...req.headers, 'x-api-key': PROXY_API_KEY };
  // Host header will be set by upstream call; strip incoming
  delete headers.host;
  // Don't preserve hop-by-hop
  delete headers.connection;

  const upstream = http.request(
    {
      hostname: TC_HOST,
      port: TC_PORT,
      path: req.url,
      method: req.method,
      headers,
    },
    (upRes) => {
      res.writeHead(upRes.statusCode || 502, upRes.headers);
      upRes.pipe(res);
    },
  );

  upstream.on('error', (err) => {
    console.error(`[relay] upstream error: ${err.message}`);
    if (!res.headersSent) {
      res.writeHead(502, { 'content-type': 'text/plain' });
    }
    res.end(`bad gateway: ${err.message}`);
  });

  req.on('error', (err) => {
    console.error(`[relay] client error: ${err.message}`);
    upstream.destroy(err);
  });

  req.pipe(upstream);
});

server.on('error', (err) => {
  console.error(`[relay] server error: ${err.message}`);
  process.exit(1);
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[relay] listening 127.0.0.1:${PORT} → ${TC_HOST}:${TC_PORT}`);
});

// Грейсфул-shutdown
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    console.log(`[relay] ${sig} received, shutting down`);
    server.close(() => process.exit(0));
  });
}
