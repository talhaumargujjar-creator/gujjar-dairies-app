# Gujjar Dairies Hisaab App

Is file ko repo ke root (`gujjar-dairies-app/`) mein `CLAUDE.md` naam se rakhein. Claude Code ye khud parhta hai.

## Kaun, kya
- Owner ki ek retail shop hai (milk, dahi, ghee, butter, bread, bun, cake, rusk, anday, bottles). Roz ka hisaab Excel sheet `JOHAR_SHOP_RETAIL_HISAAB.xlsx` mein hota tha (sheets: `ENTRY`, `FINAL HISAAB`). Ye app us sheet ki jagah le rahi hai.
- Owner technical nahi hai. **Owner se hamesha Roman Urdu mein, aasan alfaaz mein baat karo.** Code, commits aur comments English mein rakho.
- **Sab kuch free hona chahiye.** Koi paid service ya paid plan na lagao. Free tier ki limits batao agar koi hai.

## Maujooda halat
Static PWA, koi build step nahi. Files: `index.html` (HTML+CSS+JS sab ek file mein), `manifest.webmanifest`, `sw.js`, `icon-192.png`, `icon-512.png`.
- Data `localStorage` key `gd_hisaab_v2` mein (v1 wala `gd_hisaab_v1` safety ke liye chhoda hua hai, pehli baar khulne par v2 mein migrate hota hai). Har record par `u` (edit time ms), entries par `id` aur `del` (soft delete), items par `off`, `pru` (price edit time). `q` = upload ke liye baqi keys, `cur` = har table ka pull cursor, `me` = {email, role}.
- App khulte hi login page aata hai (`S.me` khali ho to). Login ke baad neeche tabs: Stock, Hisaab, Doodh, Bank, Report, Account (sync, staff manzoori, password, Backup, aur "Items, rate aur cost" ka button). Staff ko sirf Stock, Hisaab, Doodh, Account.
- Hisaab tab paper khaate (cashbook page) jaisa: kinds `ex` kharcha, `sl` salary (dono munafa mein), `cr` ghar aur gari kharcha (TOTAL PAID 2), `ud` udhaar diya (3), `bl` bill ki raqam / owner ko (4), `sp` supplier (5), `rc` cash wasool. Galla = opening + counter sale + rc + bank se nikala − sab paid − bank mein jama. Munafa = items munafa − ex − sl. Udhaar khata naam-wise: ud − rc (naam `nkey` se uppercase; "(375+375)" jaisa hissa naam ke aakhir mein hota hai aur khate mein hata diya jata hai). Raqam mein "900+900" likh sakte hain.
- Bank tab (sirf owner): `S.bk` = `ac` accounts {id,name,op} aur `tx` {id,day,ac,type,party,a,no,cd,st,note,del}. Types `BT`: jama (galle se bank, galla −), nikala (galla +), chq_diya, chq_mila, online_aaya, online_gaya. Cheque `pending` rehta hai jab tak "Clear ho gaya" na dabaya jaye; balance sirf `clear` wale ginta hai. Tables `bank_accounts`, `bank_tx` (owner-only RLS); queue keys `ba:`, `bt:`.
- Items par `ord` (register ki tarteeb). Stock mein owner "Rate ✎" daba kar sirf us din ka rate (`rt`, day_stock mein) laga sakta hai, jaise anday ka roz ka rate.
- Doodh tab Google Sheet "MILK 2026 New" ki jagah le raha hai (plan: 1 entry ✓, 2 rate/raqam/baqaya, 3 milan + PNL + Suzuki kharcha, 4 sync ✓, 5 sheet se purana data, 6 report/WhatsApp). Data `S.mk`: `ps` parties (`kind` 'sup' = doodh dene wali jaise Wasif Chacho, Bikri Bara; 'buy' = lene wali jaise Johar), `mr[day]` mandi rate {m,e} fi mann, `d[day][partyId]` = {bm,be,cm,ce,lm,le,sm,se} **kg mein** (1 mann = 40 kg; b bandhi, c cow, l mandi se liya, s mandi ko becha; m subah, e shaam). Party ka kul = b + c + l − s. Milan: dene wali parties ka kul = lene wali ka kul. Supabase tables `milk_parties` (sirf owner likhe), `milk_rates`, `milk_days`; queue keys `mp:`, `mr:`, `md:day|party`.
- Sheet ke qaide (marhala 2 ke liye): bandhi raqam = mann × party ka bandhi rate, cow = mann × cow rate, mandi = mann × mandi rate; mandi ko bechne par rate se commission katta hai (Wasif −230, Bikri −2500 fi mann). Baqaya = pichla baqaya + raqam − payment. `pending` user ko "manzoori ka intezar" screen.
- Stock card paper register jaisa: Opening, Purchase, Istemal (register ka "Being used", `us`), Closing. Bika = Opening + Purchase − Istemal − Closing.
- Hosting: GitHub repo `talhaumargujjar-creator/gujjar-dairies-app` -> Vercel project `gujjar-dairies-app` (free), main par push se auto deploy. Live: https://gujjar-dairies-app.vercel.app
- Supabase project `bpzlvcmbpyvcdzzzfsjr` (Vercel Marketplace se bana, free). Schema `supabase/schema.sql` mein. Pehla signup owner banta hai, baqi `pending` jab tak owner "Staff banayein" na kare. Delete policy kahin nahi; last-write-wins trigger `lww()` purani `u` wali write ko rad karta hai. Dusra Supabase project `hakcpkkvmhamdgmfttpc` (Vercel project `gujjar-dairies` se juda) istemal nahi hota.
- Login ke baghair bhi app pehle ki tarah sirf phone par chalti hai.
- Supabase pause se bachao: Vercel cron (`vercel.json`) roz 06:00 UTC par `api/keepalive.js` chalata hai jo `keepalive()` RPC call karta hai (`public.keepalive` table mein `last_ping` badalta hai). Ye Vercel ke `SUPABASE_URL` aur `SUPABASE_ANON_KEY` env vars istemal karta hai.

## Hisaab ka logic (sheet se, isko na bigaro)
- Opening = pichle din ki closing (pehle din ke liye item ka `op`).
- Bika hua maal = Opening + Purchase − Closing. Closing khali ho to item ginti mein nahi.
- Sale = bika hua × rate. Item munafa = bika hua × (rate − cost).
- Galla: opening galla + sale + wasooli (rc) − kharche (ex) − customer/milk payments (cr) − supplier payments (sp) = hona chahiye. Asal cash in hand se farq = galla diff.
- Munafa/nuqsan = item munafa − kharche. Supplier payment stock ki kharidari hai, kharcha nahi.
- Original sheet mein ye bhi tha jo app mein abhi nahi: milk ka alag hisaab (litre se mann, sheet ke numbers se 1 mann = 38 litre lagta hai, e.g. 1723.3 litre = 45.35 mann; owner se confirm karo; `milk sale in mun`, purchase, closing), stock ki raqam (stock op/cl amount = quantity × cost), udhaar ka hisaab (HAJI UDHAAR, HAJI WASOOL), salary ka alag section, rent/utility aur labour ke alag head.

## Karne ke kaam (is tarteeb se)
1. **Pehle check:** `index.html` browser mein chala kar dekho (phone width par bhi). Koi bug ho to theek karo. Kuch bhi badalne se pehle owner ko ek line mein batao.
2. **Excel se milan:** `JOHAR_SHOP_RETAIL_HISAAB.xlsx` (owner se maango ya repo mein rakhwao) ke 25/04/2026 ke hisaab ko app mein daal kar dekho ke sale, munafa aur galla farq sheet ke barabar aate hain ya nahi. Farq ho to wajah batao.
3. **Online sync aur login (Supabase free plan):**
   - Email/password login. Sirf owner ke aur uske staff ke accounts.
   - Tables: items, day_stock, entries (ex/cr/sp/rc), cash. Har table par Row Level Security.
   - Offline-first rakho: entry pehle local, internet aane par sync. Conflict par last-write-wins chalega lekin kabhi data silently delete na ho.
   - Roles: owner (sab dekhe) aur staff (sirf entry, rate/cost aur report nahi).
   - Sirf anon/publishable key frontend mein. **Service role key kabhi commit na karo.** Keys Vercel environment variables ya config mein rakho aur owner ko batao kahan se milti hain.
   - Supabase free project 7 din inactivity par pause ho sakta hai. Owner ko ye batao aur roz use hone ki wajah se aam taur par masla nahi.
4. **Missing features:** milk ka alag hisaab, stock ki raqam, customer udhaar ledger (naam wise baqaya), salary section.
5. **Reports:** mahine ki report, Excel/CSV aur PDF export, WhatsApp par bhejne ke liye share button.
6. **Purana data:** purani sheets se history import karne ka tool.

## Usool
- Free stack hi. Naya dependency ya service lagane se pehle owner se poocho.
- Offline kaam karna band nahi hona chahiye. Service worker ka cache version (abhi `hisaab-v6`) badlo jab files badlein.
- Maujooda `localStorage` data ko migrate karo, mita na do. Naye version se pehle Backup export ka tareeqa batao.
- Chhote chhote commits, aur har kaam ke baad `git push` taake Vercel deploy kare. Deploy hone par owner ko link batao.
- UI aasan rakho: bara text, ek haath se phone par chalne wali, Roman Urdu labels. Raqam `en-PK` format mein.
- Har badlav ke baad batao ke owner ko kya karna hai (aam taur par kuch nahi).
