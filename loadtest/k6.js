// Steady request load against the portal while a deployment happens.
//   k6 run loadtest/k6.js                                  # blue-green Service (port 8080)
//   BASE_URL=http://localhost:8081 k6 run loadtest/k6.js   # naive baseline Service
//
// Failed requests are the user-visible downtime. Approximate downtime in seconds
// is failed requests divided by RATE. This measures the app tier (the portal);
// it does not measure Power BI Service itself.
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';
const RATE = Number(__ENV.RATE || 20);

const served = new Counter('served');

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: __ENV.DURATION || '120s',
      preAllocatedVUs: 20,
      maxVUs: 100,
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.001'],
    // Declared so the per-colour counts appear in the end-of-test summary.
    'served{color:blue}': ['count>=0'],
    'served{color:green}': ['count>=0'],
    'served{color:naive}': ['count>=0'],
  },
};

export default function () {
  const res = http.get(`${BASE}/version`, { timeout: '2s' });
  const ok = check(res, { 'status is 200': (r) => r.status === 200 });
  if (ok) {
    try {
      served.add(1, { color: res.json('color') });
    } catch (e) {
      // body was not JSON; the status check above already counted success
    }
  }
}
