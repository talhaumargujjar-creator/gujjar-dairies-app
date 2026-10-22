// Called once a day by the Vercel cron in vercel.json so the free Supabase project
// never sits 7 days without activity (free projects get paused after that).
// Uses only the public anon key from the Vercel project's environment; keepalive() just bumps a timestamp.
module.exports = async (req, res) => {
  const url = process.env.SUPABASE_URL, key = process.env.SUPABASE_ANON_KEY;
  if (!url || !key) return res.status(500).json({ ok: false, error: 'SUPABASE_URL or SUPABASE_ANON_KEY missing' });
  try {
    const r = await fetch(url + '/rest/v1/rpc/keepalive', {
      method: 'POST',
      headers: { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
      body: '{}'
    });
    const body = await r.text();
    res.status(r.ok ? 200 : 502).json({ ok: r.ok, status: r.status, lastPing: r.ok ? JSON.parse(body) : body });
  } catch (e) {
    res.status(502).json({ ok: false, error: String(e) });
  }
};
