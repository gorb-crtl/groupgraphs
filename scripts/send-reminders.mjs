// Sends today's reminder pushes. Run hourly by .github/workflows/reminders.yml.
// Needs VAPID_PRIVATE_KEY (a GitHub secret). The Supabase URL, publishable key and VAPID public key are read from config.js.
import fs from "node:fs";
import webpush from "web-push";

const cfgSrc = fs.readFileSync(new URL("../config.js", import.meta.url), "utf8");
const pick = (k) => (cfgSrc.match(new RegExp(k + '\\s*:\\s*"([^"]*)"')) || [])[1] || "";
const URL_ = process.env.GG_URL || pick("url"), KEY = process.env.GG_KEY || pick("key"), PUB = pick("vapidPublicKey");
const PRIV = process.env.VAPID_PRIVATE_KEY;
if (!PRIV) { console.log("VAPID_PRIVATE_KEY isn't set; skipping."); process.exit(0); }
webpush.setVapidDetails(process.env.GG_SITE || "https://gorb-crtl.github.io/groupgraphs/", PUB, PRIV);

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
const due = await rpc("push_due", { p_key: PRIV });
const sent = [], gone = [];
for (const d of due) {
  const body = LINES[Math.floor(Math.random() * LINES.length)];
  try { await webpush.sendNotification(d.sub, JSON.stringify({ title: "GroupGraphs", body, url: "./" }), { TTL: 6 * 3600 }); sent.push(d.id); }
  catch (e) { if (e.statusCode === 404 || e.statusCode === 410) gone.push(d.id); else console.error("push failed", d.id, e.statusCode || e.message); }
}
if (sent.length || gone.length) await rpc("push_done", { p_key: PRIV, p_sent: sent, p_gone: gone });
console.log(`due ${due.length}, sent ${sent.length}, removed ${gone.length}`);
