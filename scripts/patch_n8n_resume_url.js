// Run in browser console on n8n (localhost:5678) — patches Save + Resume nodes
(async () => {
  const KEY = prompt('N8N_API_KEY') || '';
  if (!KEY) throw new Error('need N8N_API_KEY');
  const headers = { 'X-N8N-API-KEY': KEY, 'Content-Type': 'application/json' };

  const saveJs = (stage) => `const runId = $('Set run context').item.json.run_id;
const resumeUrl = String($execution.resumeUrl || '');
if (!resumeUrl) throw new Error('Missing resumeUrl — trigger via POST /webhook/auto-media-run');
const stage = '${stage}';
const fs = require('fs');
const dir = '/data/hitl/resume_map';
fs.mkdirSync(dir, { recursive: true });
const mapFile = dir + '/' + runId + '-' + stage + '.json';
fs.writeFileSync(mapFile, JSON.stringify({ run_id: runId, stage, resume_url: resumeUrl, created_at: new Date().toISOString() }) + '\\n');
return { json: Object.assign({}, $input.item.json, { run_id: runId, resume_url: resumeUrl }) };`;

  const parseJs = `const raw = $input.item.json.stdout || '{}';
let map;
try { map = JSON.parse(raw); } catch (e) { throw new Error('invalid resume map: ' + raw); }
const cb = $('Parse Telegram update').item.json;
if (!map.resume_url) throw new Error('resume_url missing in map');
let url = String(map.resume_url);
url = url.replace(/\\/(auto-media-[^/?&]+)$/, '');
url = url.replace(/(signature=[^&]+)\\/auto-media-[^&]+/, '$1');
const sep = url.indexOf('?') >= 0 ? '&' : '?';
const resume_url = url + sep + 'callback=' + encodeURIComponent(cb.callback) + '&run_id=' + encodeURIComponent(cb.run_id) + '&stage=' + encodeURIComponent(cb.stage);
return { json: Object.assign({}, cb, { resume_url }) };`;

  async function patchWorkflow(id) {
    const wf = await fetch('/api/v1/workflows/' + id, { headers: { 'X-N8N-API-KEY': KEY } }).then((r) => r.json());
    for (const n of wf.nodes) {
      if (n.name === 'Save wait resume URL (stage1)') n.parameters.jsCode = saveJs('v1');
      if (n.name === 'Save wait resume URL (stage2)') n.parameters.jsCode = saveJs('v2');
      if (n.name === 'Save wait resume URL (feedback)') n.parameters.jsCode = saveJs('feedback-v1');
      if (n.name === 'Parse wait resume map' || n.name === 'Parse wait resume map (feedback)') {
        n.parameters.jsCode = parseJs;
      }
      if (n.name && n.name.startsWith('Resume Wait')) {
        n.parameters.method = 'GET';
        delete n.parameters.sendBody;
        delete n.parameters.specifyBody;
        delete n.parameters.jsonBody;
      }
    }
    const body = { name: wf.name, nodes: wf.nodes, connections: wf.connections, settings: wf.settings };
    const put = await fetch('/api/v1/workflows/' + id, { method: 'PUT', headers, body: JSON.stringify(body) });
    if (!put.ok) throw new Error(id + ' PUT ' + put.status + ' ' + (await put.text()));
    const pub = await fetch('/api/v1/workflows/' + id + '/publish', { method: 'POST', headers: { 'X-N8N-API-KEY': KEY } });
    return { id, put: put.status, pub: pub.status };
  }

  const out = [];
  out.push(await patchWorkflow('auto-media-happy-path'));
  out.push(await patchWorkflow('auto-media-hitl-forwarder'));
  console.log(JSON.stringify(out, null, 2));
  return out;
})();
