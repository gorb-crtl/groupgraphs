// Sends today's reminder pushes and friends' nudges. Run every 10 minutes by .github/workflows/reminders.yml.
// Needs VAPID_PRIVATE_KEY (a GitHub secret). The Supabase URL and publishable key are read from config.js,
// and the matching public key from the database (both set up with keys.html).
import fs from "node:fs";
import webpush from "web-push";

const cfgSrc = fs.readFileSync(new URL("../config.js", import.meta.url), "utf8");
const pick = (k) => (cfgSrc.match(new RegExp(k + '\\s*:\\s*"([^"]*)"')) || [])[1] || "";
const URL_ = process.env.GG_URL || pick("url"), KEY = process.env.GG_KEY || pick("key");
const PRIV = process.env.VAPID_PRIVATE_KEY;
if (!PRIV) { console.log("VAPID_PRIVATE_KEY isn't set; skipping."); process.exit(0); }

async function rpc(fn, args) {
  const res = await fetch(URL_.replace(/\/$/, "") + "/rest/v1/rpc/" + fn, { method: "POST",
    headers: { "Content-Type": "application/json", apikey: KEY, ...(KEY.startsWith("eyJ") ? { Authorization: "Bearer " + KEY } : {}) },
    body: JSON.stringify(args) });
  const txt = await res.text();
  if (!res.ok) throw new Error(fn + " failed: " + res.status + " " + txt);
  return txt ? JSON.parse(txt) : null;
}

const LINES = [
  "Today's graph is up. Your friends are already judging your blank curve.",
  "New question just dropped. The group average is lonely without you.",
  "Your daily data point is overdue. Reviewer 2 has noticed.",
  "Today's question is waiting. No peeking at the results until you answer.",
  "Reminder: science needs your n = 1.",
  "Your group answered. You didn't. Awkward.",
  "Draw your curve before someone in the group chat calls you out.",
];
const PUB = await rpc("push_public_key", {});
if (!PUB) { console.log("No public key in the database yet (run the SQL from keys.html); skipping."); process.exit(0); }
webpush.setVapidDetails(process.env.GG_SITE || "https://gorb-crtl.github.io/groupgraphs/", PUB, PRIV);
const due = await rpc("push_due", { p_key: PRIV });
const sent = [], gone = [];
for (const d of due) {
  const body = LINES[Math.floor(Math.random() * LINES.length)];
  try { await webpush.sendNotification(d.sub, JSON.stringify({ title: "GroupGraphs", body, url: "./" }), { TTL: 6 * 3600 }); sent.push(d.id); }
  catch (e) { if (e.statusCode === 404 || e.statusCode === 410) gone.push(d.id); else console.error("push failed", d.id, e.statusCode || e.message); }
}
// Nudges: a friend poked someone who hasn't answered yet. Older databases without nudges.sql just skip this.
let nudges = [];
try { nudges = await rpc("nudges_due", { p_key: PRIV }); } catch (e) { console.log("no nudges:", e.message.slice(0, 80)); }
const pushedNudges = [];
for (const n of nudges) {
  const body = n.msg ? `${n.from}: "${n.msg}"` : `${n.from} nudged you. Today's graph is waiting.`;
  for (const s of n.subs || []) {
    try { await webpush.sendNotification(s.sub, JSON.stringify({ title: "Nudge from " + n.from, body, url: "./", tag: "gg-nudge-" + n.id }), { TTL: 6 * 3600 }); }
    catch (e) { if (e.statusCode === 404 || e.statusCode === 410) gone.push(s.id); else console.error("nudge push failed", n.id, e.statusCode || e.message); }
  }
  pushedNudges.push(n.id);
}
if (pushedNudges.length) await rpc("nudges_done", { p_key: PRIV, p_ids: pushedNudges });
if (sent.length || gone.length) await rpc("push_done", { p_key: PRIV, p_sent: sent, p_gone: [...new Set(gone)] });
console.log(`due ${due.length}, sent ${sent.length}, nudges ${pushedNudges.length}, removed ${gone.length}`);
