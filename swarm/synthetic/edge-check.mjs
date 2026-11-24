// Edge check: reaches the snippet the synthetic check just created through the public domain, like a user:
// DNS, TLS and nginx with an HTTPS GET, then a full interactive run over the WebSocket (the same protocol
// as the UI: subprotocols snippet-run.v1 and bearer.<jwt>, a {"type":"start"} message, frames until "done").
// Prints one JSON line {ok, detail, ms} and exits 0 when the run printed "synthetic", 1 otherwise.
//
//   node edge-check.mjs https://<domain> <token> <snippetId>

const [base, token, id] = process.argv.slice(2);
const started = Date.now();

function finish(ok, detail) {
  console.log(JSON.stringify({ ok, detail, ms: Date.now() - started }));
  process.exit(ok ? 0 : 1);
}

setTimeout(() => finish(false, 'timeout after 20 s'), 20_000);

try {
  const response = await fetch(`${base}/api/snippets/${id}`, { headers: { Authorization: `Bearer ${token}` } });
  if (response.status !== 200) finish(false, `https GET returned ${response.status}`);
} catch (error) {
  finish(false, `https GET failed: ${error.cause?.code ?? error.message}`);
}

const lines = [];
const socket = new WebSocket(`${base.replace(/^http/, 'ws')}/api/snippets/${id}/run`, ['snippet-run.v1', `bearer.${token}`]);
socket.onopen = () => socket.send(JSON.stringify({ type: 'start' }));
socket.onmessage = (event) => {
  const message = JSON.parse(event.data);
  if (message.type === 'output') {
    lines.push(message.line);
  } else if (message.type === 'done') {
    const outputs = message.outputs ?? lines;
    if (message.error) finish(false, `run error: ${message.error.rule}`);
    finish(outputs.includes('synthetic'), `run outputs: ${outputs.join(' | ')}`);
  } else if (message.type === 'rejected' || message.type === 'error') {
    finish(false, `${message.type}: ${message.detail ?? message.title ?? ''}`);
  }
};
socket.onerror = () => finish(false, 'websocket error');
socket.onclose = (event) => finish(false, `websocket closed with code ${event.code} before the run finished`);
