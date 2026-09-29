// Test-only independent Node crypto peer. No network, real credentials or data.
// Wire contract: ccsop-service request-crypto.ts / websocket-crypto.ts (0440924).
import { createCipheriv, createDecipheriv, createHash, createHmac, hkdfSync, createECDH } from 'node:crypto';
const b64 = v => Buffer.from(v).toString('base64url');
const sha = v => createHash('sha256').update(v).digest('hex');
const credentials = { apiKeyId: 'fixture-key', sessionId: 'fixture-session', apiKey: 'TEST-ONLY-NOT-A-REAL-SECRET' };
const stamp = { timestamp: '1790637402000', nonce: 'fixture-nonce', requestId: 'fixture-request' };
const key = (scope, purpose, s = stamp) => Buffer.from(hkdfSync('sha256', credentials.apiKey, `${s.timestamp}:${s.nonce}`, `ccsop:${scope}:${purpose}:${s.requestId}`, 32));
const sign = (key, canonical) => createHmac('sha256', key).update(canonical).digest('base64url');
function encrypt(key, value) {
  // Deterministic IV only in this test peer; never used in production.
  const iv = Buffer.alloc(12, 7);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(value), 'utf8'), cipher.final()]);
  return { iv: b64(iv), ciphertext: b64(ciphertext), tag: b64(cipher.getAuthTag()) };
}
function decrypt(key, data) {
  const cipher = createDecipheriv('aes-256-gcm', key, Buffer.from(data.iv, 'base64url'));
  cipher.setAuthTag(Buffer.from(data.tag, 'base64url'));
  return JSON.parse(Buffer.concat([cipher.update(Buffer.from(data.ciphertext, 'base64url')), cipher.final()]).toString('utf8'));
}
function frame(seq, payload) {
  const data = encrypt(key('websocket', 'server-to-client'), payload);
  const input = { eventType: 'fixture.changed', encrypted: true, data, seq, timestamp: Number(stamp.timestamp), traceId: 'fixture-trace' };
  input.sign = sign(key('websocket', 'message-sign'), [input.eventType, seq, input.timestamp, input.traceId, sha(JSON.stringify(data))].join('\n'));
  return input;
}
const mode = process.argv[2];
let result;
if (mode === 'fixtures') {
  const clientId = 'fixture-client';
  result = {
    credentials, stamp, clientId,
    response: { status: 1, code: 'success', data: encrypt(key('supper-interface', 'response'), { result: { count: 3, name: '测试专用' } }) },
    frames: [frame(1, { revision: 1 }), frame(2, { revision: 2 })],
    wsSign: sign(key('websocket', 'sign'), ['GET', '/ws', credentials.apiKeyId, credentials.sessionId, stamp.timestamp, stamp.nonce, stamp.requestId, sha(clientId)].join('\n')),
    cashierWsSign: sign(key('websocket', 'sign'), ['GET', '/cashier/ws', credentials.apiKeyId, credentials.sessionId, stamp.timestamp, stamp.nonce, stamp.requestId, sha('store:test-store')].join('\n')),
  };
} else {
  let raw = '';
  for await (const chunk of process.stdin) raw += chunk;
  const input = JSON.parse(raw);
  if (mode === 'handshake') {
    const ec = createECDH('prime256v1'); ec.generateKeys();
    const handshakeId = '00000000-0000-4000-8000-000000000001';
    const shared = ec.computeSecret(Buffer.from(input.clientPublicKey, 'base64url'));
    const sessionKey = Buffer.from(hkdfSync('sha256', shared, input.clientNonce, `ccsop:supper-handshake:${handshakeId}`, 32));
    result = { sessionKey: b64(sessionKey), shared: b64(shared), reply: { status: 1, code: 'success', data: {
      handshakeId, serverPublicKey: b64(ec.getPublicKey()), serverKeyVersion: 'test-only', expiresIn: 60,
      alg: { keyAgreement: 'ECDH-P256', payload: 'AES-256-GCM', kdf: 'HKDF-SHA256', sign: 'HMAC-SHA256' },
    } } };
  } else if (mode === 'handshake-request') {
    const { body, headers, sessionKey } = input;
    const k = purpose => Buffer.from(hkdfSync('sha256', Buffer.from(sessionKey, 'base64url'),
      `${headers['x-timestamp']}:${headers['x-nonce']}`, `ccsop:supper-interface:${purpose}:${headers['x-request-id']}`, 32));
    if (headers['x-api-key-id'] || headers['x-session-id']) throw Error('mixed authentication');
    const canonical = ['POST', '/supper-interface', headers['x-handshake-id'], '', headers['x-timestamp'],
      headers['x-nonce'], headers['x-request-id'], sha(JSON.stringify(body.data))].join('\n');
    if (body.sign !== sign(k('sign'), canonical)) throw Error('handshake signature mismatch');
    const request = decrypt(k('request'), body.data);
    result = { request, reply: { status: 1, code: 'success', data: encrypt(k('response'), {
      result: { apiKey: 'TEST-ONLY-ISSUED-KEY', interfaceId: request.interfaceId },
    }) } };
  } else if (mode === 'request') {
    const { body, headers } = input;
    const s = { timestamp: headers['x-timestamp'], nonce: headers['x-nonce'], requestId: headers['x-request-id'] };
    const canonical = ['POST', '/supper-interface', headers['x-api-key-id'], headers['x-session-id'], s.timestamp, s.nonce, s.requestId, sha(JSON.stringify(body.data))].join('\n');
    if (body.sign !== sign(key('supper-interface', 'sign', s), canonical)) throw Error('signature mismatch');
    result = decrypt(key('supper-interface', 'request', s), body.data);
  } else if (mode === 'outbound') {
    const canonical = [input.eventType, input.seq, input.timestamp, input.traceId ?? '', sha(JSON.stringify(input.data))].join('\n');
    if (input.sign !== sign(key('websocket', 'message-sign'), canonical)) throw Error('signature mismatch');
    result = decrypt(key('websocket', 'client-to-server'), input.data);
  } else throw Error('unknown mode');
}
process.stdout.write(JSON.stringify(result));
