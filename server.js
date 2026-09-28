const express = require('express');
const app = express();
const port = process.env.PORT || 8080;

app.get('/', (req, res) => {
  res.json({
    message: 'Hello from Azure App Service!',
    version: process.env.APP_VERSION || 'dev',
    timestamp: new Date().toISOString(),
  });
});

// Health endpoint used by App Service health checks and pipeline smoke tests
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'healthy' });
});

app.listen(port, () => {
  console.log(`App listening on port ${port}`);
});
