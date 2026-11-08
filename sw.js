const C='hisaab-v90',LIB='https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js',PDFL=['https://cdn.jsdelivr.net/npm/html2canvas@1.4.1/dist/html2canvas.min.js','https://cdn.jsdelivr.net/npm/jspdf@2.5.1/dist/jspdf.umd.min.js'],F=['/','/index.html','/manifest.webmanifest','/icon-192.png','/icon-512.png','/img/logo.png','/img/mascot.png','/img/tagline.png','/khata-form.html','/delivery-form.html',LIB,...PDFL];
self.addEventListener('install',e=>{e.waitUntil(caches.open(C).then(c=>c.addAll(F)));self.skipWaiting()});
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==C).map(x=>caches.delete(x)))).then(()=>self.clients.claim())));
// Only the app's own files and the pinned libraries are cached. Supabase data requests always go to the network.
self.addEventListener('fetch',e=>{const u=new URL(e.request.url);if(e.request.method!=='GET'||(u.origin!==location.origin&&e.request.url!==LIB&&!PDFL.includes(e.request.url)))return;
 e.respondWith(fetch(e.request).then(r=>{if(r.ok){const c=r.clone();caches.open(C).then(x=>x.put(e.request,c))}return r}).catch(()=>caches.match(e.request).then(r=>r||caches.match('/'))))});
