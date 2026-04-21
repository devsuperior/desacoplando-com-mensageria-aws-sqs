import http from 'k6/http';
import { check, sleep } from 'k6';
import { uuidv4 } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

export const options = {
  stages: [
    { duration: '30s', target: 80 },
    { duration: '120s', target: 150 },
    { duration: '30s', target: 200 },
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.02'],
    http_req_duration: ['p(95)<2000'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8081';
const CURRENCIES = ['BRL', 'USD', 'EUR'];

export default function () {
  const correlationId = uuidv4();
  const paymentId = `pay_${uuidv4()}`;
  const amount = (Math.random() * 900 + 100).toFixed(2);
  const currency = CURRENCIES[Math.floor(Math.random() * CURRENCIES.length)];

  const payload = JSON.stringify({
    paymentId,
    amount: parseFloat(amount),
    currency,
    status: 'succeeded',
    createdAt: new Date().toISOString(),
  });

  const params = {
    headers: {
      'Content-Type': 'application/json',
      'X-Correlation-ID': correlationId,
    },
  };

  const res = http.post(`${BASE_URL}/api/payments/webhook`, payload, params);

  check(res, {
    'status is 202': (r) => r.status === 202,
    'response contains correlationId': (r) => r.body && r.body.includes('correlationId'),
  });

  sleep(Math.random() * 0.3);
}
