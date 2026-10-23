// Reads photos of the daily khata (paper register) with Google Gemini (free tier) and returns
// the numbers as JSON for the app to review. Only signed-in owner/staff can call it, so the
// Gemini key in the Vercel environment (GEMINI_API_KEY) cannot be used by strangers.
const MODEL = process.env.GEMINI_MODEL || 'gemini-2.5-flash';

const SCHEMA = {
  type: 'OBJECT',
  properties: {
    date: { type: 'STRING', nullable: true, description: 'Date written on the page as YYYY-MM-DD' },
    stock: { type: 'ARRAY', items: { type: 'OBJECT', properties: {
      id: { type: 'STRING', description: 'Item id from the given list' },
      op: { type: 'NUMBER', nullable: true }, pu: { type: 'NUMBER', nullable: true },
      us: { type: 'NUMBER', nullable: true }, cl: { type: 'NUMBER', nullable: true },
      sure: { type: 'BOOLEAN' }, note: { type: 'STRING', nullable: true } }, required: ['id', 'sure'] } },
    unknown_items: { type: 'ARRAY', items: { type: 'OBJECT', properties: {
      name: { type: 'STRING' }, op: { type: 'NUMBER', nullable: true }, pu: { type: 'NUMBER', nullable: true },
      us: { type: 'NUMBER', nullable: true }, cl: { type: 'NUMBER', nullable: true } }, required: ['name'] } },
    entries: { type: 'ARRAY', items: { type: 'OBJECT', properties: {
      kind: { type: 'STRING', enum: ['ex', 'sl', 'cr', 'ud', 'bl', 'sp', 'rc'] },
      name: { type: 'STRING' }, amount: { type: 'NUMBER' }, parts: { type: 'STRING', nullable: true },
      sure: { type: 'BOOLEAN' }, note: { type: 'STRING', nullable: true } }, required: ['kind', 'name', 'amount', 'sure'] } },
    galla_open: { type: 'NUMBER', nullable: true },
    cash: { type: 'NUMBER', nullable: true }
  },
  required: ['stock', 'entries']
};

function prompt(items) {
  return `You read photos of a Pakistani dairy shop's handwritten daily register ("khata") and return the numbers as JSON.
The photos are the pages of ONE day. They may be the shop's printed form (codes P1, P2, P3 at the top right, items numbered with #)
or the older register (ITEM BALANCING FORM AND COUNTER SALE + an Urdu cashbook page).

ITEMS (use these ids; match by row number "#" on the new form or by printed/written name on the old register):
${items.map((it, i) => `${i + 1}. ${it.id} = ${it.name}`).join('\n')}

Stock columns: OPENING/OP. BAL. -> op, PURCHASE -> pu, ISTEMAL/BEING USED -> us, CLOSING/CLOSING BAL. -> cl.
Ignore TOTAL IN, SALE, RATE, AMOUNT columns. A dash "—" or empty box means null, except a dash in CLOSING means 0.
Kg values like "8kg" are just 8. Return one stock row per item that has any number. Rows on a photo slope; follow the printed lines.

Cashbook sections -> kind:
ex = KHARCHA / خرچہ (general expenses, left column on the old page, K1 on the new form)
sl = SALARY EXPENSE / salary names (K2)
cr = SUZUKI KAAM, DRIVER SALARY, TALHA BHAI GHAR KHARCHA, TALHA BHAI PARCEL ... TOTAL PAID (2) (K3)
ud = ادھار UDHAAR names like HAJI HOTEL, DELIVERY, MUNAWWAR ALI (K4)
bl = بل کی رقم BILL KI RAQAM: SUZUKI PETROL, TALHA CASH SHOP, ROZ RAQAM, TALHA ACCOUNT (K5)
sp = SUPPLIER PAYMENT (K6)
rc = کیش وصول CASH WASOOL (K7). Do NOT return a "COUNTER SALE" row.
Skip rows with no amount. Skip printed TOTAL rows. Skip the "دودھ آیا" milk table.
Names: write in Roman Urdu CAPITALS (e.g. لیبر خرچی -> LABOUR KHARCHI, طلحہ بھائی -> TALHA BHAI). If two amounts are added
like 900+900, give amount 1800 and parts "900+900".
galla_open = GALLA OPENING / GALLA OP. BAL., cash = GALLE MEIN ASAL CASH (counted cash), null if not written.

Set sure=false and explain in note (short, simple English) whenever a digit is unclear, overwritten, crossed out,
two numbers are written in one box, the numbers don't add up (op+pu must equal TOTAL IN when it is written), or the
closing is bigger than opening+purchase. Never guess silently. Items written on the page that are not in the list go in unknown_items.`;
}

async function checkMember(token) {
  const url = process.env.SUPABASE_URL, key = process.env.SUPABASE_ANON_KEY;
  if (!token || !url || !key) return false;
  const r = await fetch(url + '/rest/v1/rpc/is_member', {
    method: 'POST', headers: { apikey: key, Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' }, body: '{}'
  });
  return r.ok && (await r.json()) === true;
}

module.exports = async (req, res) => {
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });
  try {
    const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
    if (!(await checkMember(token))) return res.status(401).json({ error: 'login' });
    if (!process.env.GEMINI_API_KEY) return res.status(503).json({ error: 'no_key' });
    const { images, items } = req.body || {};
    if (!Array.isArray(images) || !images.length || images.length > 4 || !Array.isArray(items))
      return res.status(400).json({ error: 'bad_request' });
    const parts = [{ text: prompt(items.slice(0, 200)) }];
    for (const b64 of images) parts.push({ inline_data: { mime_type: 'image/jpeg', data: String(b64) } });
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': process.env.GEMINI_API_KEY },
      body: JSON.stringify({ contents: [{ role: 'user', parts }],
        generationConfig: { temperature: 0, responseMimeType: 'application/json', responseSchema: SCHEMA } })
    });
    const body = await r.json();
    if (!r.ok) return res.status(502).json({ error: 'gemini', status: r.status, detail: body.error && body.error.message });
    const text = body.candidates && body.candidates[0] && body.candidates[0].content && body.candidates[0].content.parts.map(p => p.text || '').join('');
    if (!text) return res.status(502).json({ error: 'empty' });
    res.status(200).json(JSON.parse(text));
  } catch (e) {
    res.status(500).json({ error: 'server', detail: String(e && e.message || e) });
  }
};
