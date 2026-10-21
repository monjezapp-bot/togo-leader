// Standalone no-dependency synthetic hosting prototype. No WhatsApp connection or sends.
import { createHash, timingSafeEqual, randomBytes, createCipheriv, createDecipheriv } from 'node:crypto';

export const fixtures = Object.freeze([
  { orderId: 'DEMO-001', name: 'عميل تجريبي ١', phone: 'DEMO-NOT-A-PHONE-1' },
  { orderId: 'DEMO-002', name: 'عميل تجريبي ٢', phone: 'DEMO-NOT-A-PHONE-2' }
]);

export function authorize(header, token) {
  if (typeof token !== 'string' || token.length < 32) return false;
  if (typeof header !== 'string') return false;
  const expected = Buffer.from(`Bearer ${token}`);
  const supplied = Buffer.from(header);
  return supplied.length === expected.length && timingSafeEqual(supplied, expected);
}

export function seal(value, key, context) {
  if (!Buffer.isBuffer(key) || key.length !== 32) throw new Error('32-byte encryption key required');
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  cipher.setAAD(Buffer.from(context));
  const data = Buffer.concat([cipher.update(JSON.stringify(value)), cipher.final()]);
  return { v: 1, iv: iv.toString('base64'), tag: cipher.getAuthTag().toString('base64'), data: data.toString('base64') };
}

export function open(envelope, key, context) {
  if (envelope.v !== 1) throw new Error('Unsupported envelope');
  const decipher = createDecipheriv('aes-256-gcm', key, Buffer.from(envelope.iv, 'base64'));
  decipher.setAAD(Buffer.from(context));
  decipher.setAuthTag(Buffer.from(envelope.tag, 'base64'));
  return JSON.parse(Buffer.concat([decipher.update(Buffer.from(envelope.data, 'base64')), decipher.final()]).toString());
}

export class Prototype {
  #jobs = new Map();
  create(input) {
    // Only fixed synthetic records are accepted. No phone numbers, message bodies,
    // customer names, or live order identifiers can enter this prototype.
    if (!input || Object.keys(input).some(k => !['jobId', 'fixtureIds'].includes(k))) throw new Error('Synthetic fixture IDs only');
    const { jobId, fixtureIds } = input;
    if (typeof jobId !== 'string' || !/^DEMO-[A-Za-z0-9-]{1,64}$/.test(jobId)) throw new Error('Invalid demo job ID');
    if (!Array.isArray(fixtureIds) || !fixtureIds.length || fixtureIds.length > 2 || new Set(fixtureIds).size !== fixtureIds.length) throw new Error('Invalid fixture selection');
    const selected = fixtureIds.map(id => {
      const item = fixtures.find(f => f.orderId === id);
      if (!item) throw new Error('Unknown synthetic fixture');
      return item;
    });
    const digest = createHash('sha256').update(JSON.stringify([...fixtureIds].sort())).digest('hex');
    const previous = this.#jobs.get(jobId);
    if (previous) {
      if (previous.digest !== digest) throw new Error('Job ID reused with different selection');
      return { ...previous.result, duplicate: true };
    }
    const result = { jobId, state: 'preview_only', sent: 0, pairingEnabled: false, sendingEnabled: false,
      warning: 'Synthetic preview only. This is not a WhatsApp delivery test.',
      preview: selected.map(item => ({ ...item, text: 'نص تجريبي فقط. لن يتم إرسال أي رسالة.' })) };
    this.#jobs.set(jobId, { digest, result });
    // Bounded ephemeral demo cache, explicitly not a durable sending ledger.
    if (this.#jobs.size > 100) this.#jobs.delete(this.#jobs.keys().next().value);
    return { ...result, duplicate: false };
  }
}

// Pure reducer for SYNTHETIC data. No sockets, history sync or WhatsApp dependency.
// Numeric receipt values match Baileys proto.WebMessageInfo.Status in 7.0.0-rc14.
const receiptRank = new Map([[2,'server_accepted'],[3,'delivered'],[4,'read']]);
const knownKeys = new Set(['eventId','orderId','kind','status','latitude','longitude','observedAt']);
export class DemoInbox {
  #orders = new Map();
  #seen = new Set();
  #connected = false;
  #caughtUp = false;
  #lastSync = null;
  constructor() {
    for (const id of ['DEMO-001','DEMO-002']) this.#orders.set(id, {
      orderId:id, receipt:'unknown', receiptRank:0, replied:false, questionAvailable:false, location:null
    });
  }
  connection({connected,caughtUp=false,observedAt}) {
    if (typeof connected !== 'boolean' || typeof caughtUp !== 'boolean' || !validTime(observedAt)) throw new Error('Invalid demo connection update');
    this.#connected = connected;
    this.#caughtUp = connected && caughtUp;
    if (this.#caughtUp) this.#lastSync = observedAt;
    return this.snapshot();
  }
  accept(event) {
    if (!event || Object.keys(event).some(k => !knownKeys.has(k))) throw new Error('No text or phone data accepted');
    if (!/^DEMO-EVT-[A-Za-z0-9-]{1,64}$/.test(event.eventId || '') || !validTime(event.observedAt)) throw new Error('Invalid synthetic event');
    if (!this.#orders.has(event.orderId)) return {ignored:true};
    if (this.#seen.has(event.eventId)) return {duplicate:true};
    const item = this.#orders.get(event.orderId);
    switch (event.kind) {
      case 'receipt': {
        if (!receiptRank.has(event.status)) throw new Error('Unsupported demo receipt');
        // Delivery and read receipt events can arrive out of order.
        if (event.status > item.receiptRank) {
          item.receiptRank = event.status;
          item.receipt = receiptRank.get(event.status);
        }
        break;
      }
      case 'reply': item.replied = true; break;
      case 'question': item.replied = true; item.questionAvailable = true; break;
      case 'location':
        if (!Number.isFinite(event.latitude) || !Number.isFinite(event.longitude) || event.latitude < -90 || event.latitude > 90 || event.longitude < -180 || event.longitude > 180) throw new Error('Invalid coordinates');
        // Synthetic zero coordinates only. Never collect a real customer's position here.
        if (event.latitude !== 0 || event.longitude !== 0) throw new Error('Demo coordinates must be zero');
        item.replied = true;
        item.location = {latitude:0, longitude:0, observedAt:event.observedAt, synthetic:true};
        break;
      default: throw new Error('Unsupported event');
    }
    this.#seen.add(event.eventId);
    // Ephemeral demo-only dedupe. A production ledger must be durable and ordered.
    if (this.#seen.size > 1000) this.#seen.delete(this.#seen.values().next().value);
    return {accepted:true};
  }
  snapshot() {
    return {synthetic:true, connected:this.#connected, caughtUp:this.#caughtUp, lastSync:this.#lastSync,
      state:this.#caughtUp ? 'demo_synced' : 'not_synced',
      orders:[...this.#orders.values()].map(({receiptRank,...item}) => ({...item,
        replyStatus:item.replied ? 'reply_observed' : (this.#caughtUp ? 'no_reply_observed' : 'unknown_until_synced'),
        readStatus:item.receipt === 'read' ? 'read_observed' : 'unknown'
      }))};
  }
}
function validTime(value) {
  return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(value) && Number.isFinite(Date.parse(value));
}

import http from 'node:http';
import { pathToFileURL } from 'node:url';

export function makeServer(token) {
  if (!token || token.length < 32) throw new Error('Set a server-only DEMO_ADMIN_TOKEN of at least 32 characters');
  const prototype = new Prototype();
  const inbox = new DemoInbox();
  return http.createServer(async (req, res) => {
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    // No CORS grants and no frontend-embedded token. Live Leader integration is disabled.
    const reply = (status, data) => { res.writeHead(status); res.end(JSON.stringify(data)); };
    if (req.method === 'GET' && req.url === '/health') return reply(200, { ok: true, mode: 'synthetic_no_send' });
    if (!authorize(req.headers.authorization, token)) return reply(401, { error: 'Unauthorized' });
    if (req.url === '/pair' || req.url === '/send') return reply(403, { error: 'Pairing and sending are not implemented or permitted in this prototype' });
    if (req.method === 'GET' && req.url === '/demo/inbox') return reply(200, inbox.snapshot());
    if (req.method !== 'POST' || !['/demo/preview','/demo/event','/demo/connection'].includes(req.url)) return reply(404, { error: 'Not found' });
    if (req.headers['content-type'] !== 'application/json') return reply(415, { error: 'application/json required' });
    let size = 0;
    const chunks = [];
    try {
      for await (const chunk of req) {
        size += chunk.length;
        if (size > 2048) { reply(413, { error: 'Body too large' }); req.resume(); return; }
        chunks.push(chunk);
      }
      const data = JSON.parse(Buffer.concat(chunks).toString());
      if (req.url === '/demo/event') return reply(200, inbox.accept(data));
      if (req.url === '/demo/connection') return reply(200, inbox.connection(data));
      return reply(200, prototype.create(data));
    } catch {
      return reply(400, { error: 'Invalid synthetic preview request' });
    }
  });
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const server = makeServer(process.env.DEMO_ADMIN_TOKEN);
  server.requestTimeout = 10000;
  server.listen(Number(process.env.PORT || 3000), process.env.BIND_HOST || '127.0.0.1');
}
