// Minimal smoke test: boots the app in-process and hits /health.
// Kept dependency-free so it runs fast inside the pipeline's Test stage.
const http = require('http');
const { spawn } = require('child_process');

const port = 8099;
const child = spawn('node', ['server.js'], {
  cwd: __dirname + '/..',
  env: { ...process.env, PORT: port },
});

const timeout = setTimeout(() => {
  console.error('Smoke test timed out waiting for app to respond');
  child.kill();
  process.exit(1);
}, 8000);

function check(retries) {
  http
    .get(`http://localhost:${port}/health`, (res) => {
      if (res.statusCode === 200) {
        console.log('Smoke test passed: /health returned 200');
        clearTimeout(timeout);
        child.kill();
        process.exit(0);
      } else {
        retryOrFail(retries);
      }
    })
    .on('error', () => retryOrFail(retries));
}

function retryOrFail(retries) {
  if (retries <= 0) {
    clearTimeout(timeout);
    child.kill();
    console.error('Smoke test failed: app did not become healthy');
    process.exit(1);
  }
  setTimeout(() => check(retries - 1), 500);
}

setTimeout(() => check(10), 800);
