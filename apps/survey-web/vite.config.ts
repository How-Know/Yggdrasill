import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [
    react(),
    {
      name: 'timing-log',
      configureServer(server) {
        server.middlewares.use((req, res, next) => {
          if (!req.url || !req.url.startsWith('/__timing_log')) return next();
          res.setHeader('Access-Control-Allow-Origin', '*');
          res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
          res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
          if (req.method === 'OPTIONS') {
            res.statusCode = 204;
            res.end();
            return;
          }
          if (req.method !== 'POST') {
            res.statusCode = 405;
            res.end();
            return;
          }
          let body = '';
          req.on('data', (chunk) => {
            body += chunk;
          });
          req.on('end', () => {
            try {
              const data = JSON.parse(body || '{}');
              const msg = typeof data?.message === 'string' ? data.message : '';
              if (msg) console.log(`[timing] ${msg}`);
              else if (body.trim()) console.log(`[timing] ${body.trim()}`);
            } catch (e) {
              if (body.trim()) console.log(`[timing] ${body.trim()}`);
              else console.log('[timing] invalid payload');
            }
            res.statusCode = 204;
            res.end();
          });
        });
      },
    },
  ],
});



