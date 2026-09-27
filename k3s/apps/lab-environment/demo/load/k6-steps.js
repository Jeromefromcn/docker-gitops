// Stepped open-model load: the arrival rate is fixed per step whatever the
// latency, so the knee shows as P99 departing while RPS keeps its target.
// Hard cap: 80 req/s, 80 VUs, 6 minutes.
import http from 'k6/http';

const BASE = __ENV.TARGET || 'http://10.0.0.95:30097';
const PATHS = ['/api/customer/owners', '/api/gateway/owners/6', '/api/vet/vets', '/api/customer/owners/3'];

export const options = {
  scenarios: {
    steps: {
      executor: 'ramping-arrival-rate',
      startRate: 5,
      timeUnit: '1s',
      preAllocatedVUs: 20,
      maxVUs: 80,
      stages: [
        { target: 5, duration: '1m' },
        { target: 10, duration: '1m' },
        { target: 20, duration: '1m' },
        { target: 40, duration: '1m' },
        { target: 60, duration: '1m' },
        { target: 80, duration: '1m' },
      ],
    },
  },
  summaryTrendStats: ['med', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  http.get(BASE + PATHS[Math.floor(Math.random() * PATHS.length)], { timeout: '10s' });
}
