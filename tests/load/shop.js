// ShopFlow load test: shoppers browse, fill a cart and check out, through the
// same Ingress real users hit.
//
//   k6 run tests/load/shop.js                                  # default: ramp to 12 shoppers
//   BASE_URL=https://shop.localtest.me:9443 k6 run tests/load/shop.js
//   PROFILE=smoke k6 run tests/load/shop.js                    # 1 shopper, 30 s
//
// Fails (exit code 99) when a threshold is crossed, so it can gate a pipeline.
import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const BASE = __ENV.BASE_URL || 'https://shop.localtest.me:9443';
const PROFILE = __ENV.PROFILE || 'load';
const TARGET = Number(__ENV.TARGET || 12);

const checkoutOk = new Rate('checkout_success');
const checkoutTime = new Trend('checkout_duration', true);

const profiles = {
  smoke: { vus: 1, duration: '30s' },
  // Sized for a laptop cluster. On AKS raise TARGET (e.g. TARGET=100).
  load: {
    stages: [
      { duration: '1m', target: Math.ceil(TARGET / 3) },
      { duration: '3m', target: TARGET },
      { duration: '1m', target: 0 },
    ],
  },
  // Used by the chaos test: steady traffic while pods are killed and the
  // network to the database is slowed down.
  chaos: { vus: 6, duration: '6m' },
};

export const options = {
  ...profiles[PROFILE],
  insecureSkipTLSVerify: true, // the local CA isn't in k6's trust store
  // *.localtest.me also resolves to ::1, but kind only listens on IPv4.
  hosts: { 'shop.localtest.me': '127.0.0.1' },
  thresholds: {
    http_req_failed: ['rate<0.01'],                 // under 1% errors
    'http_req_duration{api:products}': ['p(95)<500'],
    checkout_success: ['rate>0.99'],
    checkout_duration: ['p(95)<1500'],
  },
};

const json = { headers: { 'Content-Type': 'application/json' } };

export default function () {
  const user = `k6-${__VU}-${__ITER}`;

  const products = group('browse', () => {
    http.get(`${BASE}/`, { tags: { api: 'home' } });
    const res = http.get(`${BASE}/api/products`, { tags: { api: 'products' } });
    check(res, { 'products listed': (r) => r.status === 200 && r.json().length > 0 });
    return res.status === 200 ? res.json() : [];
  });
  if (products.length === 0) { sleep(1); return; } // don't hammer a failing shop
  sleep(1);

  const picks = [products[__ITER % products.length], products[(__ITER + 3) % products.length]];
  group('cart', () => {
    for (const p of picks) {
      http.get(`${BASE}/api/products/${p.id}`, { tags: { api: 'product' } });
      const res = http.put(`${BASE}/api/cart/${user}/items/${p.id}`, JSON.stringify({ quantity: 1 }),
        { ...json, tags: { api: 'cart' } });
      check(res, { 'added to cart': (r) => r.status === 200 });
    }
  });
  sleep(1);

  group('checkout', () => {
    const body = JSON.stringify({
      customerEmail: `${user}@example.com`,
      items: picks.map((p) => ({ productId: p.id, quantity: 1 })),
    });
    const res = http.post(`${BASE}/api/orders`, body, { ...json, tags: { api: 'orders' } });
    const ok = check(res, { 'order placed': (r) => r.status === 201 || r.status === 200 });
    checkoutOk.add(ok);
    checkoutTime.add(res.timings.duration);
    http.del(`${BASE}/api/cart/${user}`, null, { tags: { api: 'cart' } });
  });
  sleep(2);
}
