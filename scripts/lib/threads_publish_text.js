// n8n Code node: Prepare Threads publish — extract first post, clamp to API limit (500).
const fs = require('fs');
const MAX = 500;
const runId = $('Set run context').item.json.run_id;
const postPath = `/data/runs/${runId}/post.md`;
if (!fs.existsSync(postPath)) {
  throw new Error(`missing ${postPath} — run copywriter first`);
}
const raw = fs.readFileSync(postPath, 'utf8');

function pickThreadsText(md) {
  const s = md.trim();
  let m = s.match(/##\s*第\s*1\s*則[\s\S]*?(?=\n##\s*第\s*2\s*則|$)/);
  if (m) return m[0].trim();
  m = s.match(/###\s*貼文\s*1[\s\S]*?(?=\n###\s*貼文\s*2|$)/i);
  if (m) return m[0].trim();
  if (!/##\s*Part\s*2/i.test(s) && !/第\s*2\s*則/.test(s)) {
    const head = s.match(/^##\s+.+[\s\S]*/m);
    if (head) return head[0].trim();
  }
  m = s.match(/^[\s\S]*?(?=\n##\s*第\s*2\s*則|\n##\s*Part\s*2|\n---\s*$)/m);
  return (m ? m[0] : s).trim();
}

function clamp(t) {
  if (t.length <= MAX) return t;
  let cut = t.slice(0, MAX - 1);
  const nl = cut.lastIndexOf('\n');
  if (nl > MAX * 0.6) cut = cut.slice(0, nl);
  else cut = cut.replace(/\s+\S*$/, '');
  return cut.trimEnd() + '…';
}

const picked = pickThreadsText(raw);
const text = clamp(picked);
const image_url = String($json.stdout ?? '').trim();
if (!image_url) {
  throw new Error('missing catbox image_url from Upload image to catbox');
}
return {
  json: {
    run_id: runId,
    text,
    image_url,
    text_chars: text.length,
    threads_truncated: picked.length > MAX || raw.trim().length > text.length,
  },
};
