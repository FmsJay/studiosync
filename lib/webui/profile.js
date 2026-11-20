// Everyone's profile in the web UI (lib/profile.lua builds the "profiles" topic: a display name, a colour and a small picture each). Gives
// the other pages window.ssProfiles:
//   ssProfiles.avatar(user, px)  a round picture (or initials on the person's colour) as an element, to put beside a name
//   ssProfiles.name(user)        the display name, else the user name;  ssProfiles.colour(user)  "#rrggbb" or null
//   ssProfiles.edit()            opens "Your profile" (display name, colour, picture)
// and puts an avatar at the front of any element with a data-av-user attribute, now and whenever profiles change (app.js's people list does;
// the chat can too: set data-av-user on a message row). A picture is only ever an <img> of a data: PNG or JPEG the server checked; a picture
// you pick is drawn into a 96 px canvas here and sent as a fresh JPEG (the server checks it again, and refuses anything else). Names go in as
// text, never HTML. GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  if (!window.ssTabs) return;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const PIC_MAX = 9800; // (bytes: lib/profile.lua takes 10,000)
  let P = null;
  const people = () => (P && P.people) || {};
  function initials(s) {
    const w = String(s || '?').trim().split(/\s+/).filter(Boolean);
    return ((w[0] || '?')[0] + (w.length > 1 ? w[w.length - 1][0] : '')).toUpperCase();
  }
  const name = (u) => { const p = people()[u]; return (p && p.name) || u; };
  const colour = (u) => { const p = people()[u]; return (p && p.colour) || null; };
  function avatar(u, px) {
    const p = people()[u] || {};
    const a = mk('span', 'av');
    a.dataset.avKey = u + '|' + (p.pic ? p.pic.length + p.pic.slice(-24) : '') + '|' + (p.colour || '') + '|' + (p.name || '');
    if (px) { a.style.width = a.style.height = px + 'px'; a.style.fontSize = Math.round(px * 0.42) + 'px'; }
    if (p.colour) a.style.setProperty('--avc', p.colour);
    if (p.pic && /^data:image\/(png|jpeg);base64,[A-Za-z0-9+/=]+$/.test(p.pic)) {
      const i = mk('img');
      i.src = p.pic; i.alt = ''; i.decoding = 'async';
      a.append(i);
    } else a.textContent = initials(p.name || u);
    a.setAttribute('aria-hidden', 'true');
    a.title = name(u);
    return a;
  }
  // (an avatar at the front of each [data-av-user] element, replaced only when that person's profile changed)
  function decorate(root) {
    const list = root.matches && root.matches('[data-av-user]') ? [root] : [];
    if (root.querySelectorAll) list.push(...root.querySelectorAll('[data-av-user]'));
    for (const e of list) {
      const u = e.dataset.avUser, first = e.firstElementChild;
      const fresh = avatar(u, Number(e.dataset.avSize) || 0);
      if (first && first.classList.contains('av')) { if (first.dataset.avKey !== fresh.dataset.avKey) first.replaceWith(fresh); }
      else e.prepend(fresh);
    }
  }
  new MutationObserver((ms) => {
    for (const m of ms) for (const n of m.addedNodes) if (n.nodeType === 1 && !n.classList.contains('av')) decorate(n);
  }).observe(document.body, { childList: true, subtree: true });

  function take() {
    const p = ssTabs.topics.profiles;
    if (!p || p === P) return;
    P = p;
    decorate(document.body);
    dispatchEvent(new CustomEvent('ss-profiles'));
    if (P.reply && pendingId && P.reply.id === pendingId) { pendingId = null; said(P.reply.ok ? 'Saved.' : 'Not saved: ' + (P.reply.why || 'refused'), !P.reply.ok); if (P.reply.ok) setTimeout(() => dlg.open && dlg.close(), 700); }
  }
  addEventListener('ss-state', take);
  addEventListener('ss-tabs', take);

  // ---- Your profile ------------------------------------------------------------------------------------------------------------------
  const dlg = mk('dialog', 'pfdlg');
  dlg.setAttribute('aria-labelledby', 'pfdlg-h');
  // (fixed markup, no data in it)
  dlg.innerHTML = '<form method="dialog" class="pfform">' +
    '<h2 id="pfdlg-h">Your profile</h2>' +
    '<div class="pfrow1"><span class="pfprev"></span><div class="pfpick">' +
    '<label class="pfbtn">Choose a picture<input type="file" accept="image/png,image/jpeg" hidden></label>' +
    '<button type="button" class="pfnopic">No picture</button>' +
    '<p class="dim pfnote">PNG or JPEG. Cropped square and made small here; everyone in the studio sees it.</p></div></div>' +
    '<label class="pffield2">Display name <input class="pfname" maxlength="40" autocomplete="off" placeholder="as the band knows you"></label>' +
    '<div class="pffield2">Colour <input type="color" class="pfcol" aria-label="Your colour"> <button type="button" class="pfcoldef">Default</button>' +
    '<span class="dim pfnote">yours in every studio: drawings, chat and here</span></div>' +
    '<p class="pfsaid" role="status"></p>' +
    '<div class="pfacts"><button type="button" class="pfcancel">Cancel</button><button type="submit" class="pfsave">Save</button></div>' +
    '</form>';
  document.body.append(dlg);
  const q = (s) => dlg.querySelector(s);
  const prev = q('.pfprev'), file = q('input[type=file]'), nameIn = q('.pfname'), col = q('.pfcol'), saidEl = q('.pfsaid');
  let pic = undefined, colDefault = false, pendingId = null, me = null;
  function said(t, bad) { saidEl.textContent = t || ''; saidEl.classList.toggle('bad', !!bad); }
  function preview() {
    prev.replaceChildren();
    const a = avatar(me, 72);
    if (pic === '') { a.replaceChildren(); a.textContent = initials(nameIn.value || me); }
    else if (pic) { a.replaceChildren(); const i = mk('img'); i.src = pic; i.alt = ''; a.append(i); }
    a.style.setProperty('--avc', col.value);
    prev.append(a);
  }
  function edit() {
    me = (P && P.me) || null;
    if (!me) { const p = ssTabs.topics.presence; const x = p && (p.people || []).find((y) => y.me); me = x ? x.user : null; }
    if (!me) return;
    const p = people()[me] || {};
    nameIn.value = p.name || '';
    col.value = p.colour || '#d9822b';
    pic = undefined; colDefault = false; file.value = ''; said('');
    preview();
    if (dlg.showModal) dlg.showModal(); else dlg.setAttribute('open', '');
    nameIn.focus();
  }
  // a picked file -> a fresh 96 px JPEG data: URL under PIC_MAX bytes (the browser decodes it; nothing of the file itself is sent)
  function encode(f) {
    return new Promise((res, rej) => {
      if (!/^image\/(png|jpeg)$/.test(f.type)) return rej(new Error('only PNG or JPEG pictures'));
      if (f.size > 20 * 1024 * 1024) return rej(new Error('that file is too big'));
      const fr = new FileReader();
      fr.onerror = () => rej(new Error('that file couldn’t be read'));
      fr.onload = () => {
        const img = new Image();
        img.onerror = () => rej(new Error('that isn’t a picture this browser can read'));
        img.onload = () => {
          const c = document.createElement('canvas'), N = 96;
          c.width = c.height = N;
          const s = Math.min(img.naturalWidth, img.naturalHeight);
          const g = c.getContext('2d');
          g.fillStyle = '#ffffff'; g.fillRect(0, 0, N, N);
          g.drawImage(img, (img.naturalWidth - s) / 2, (img.naturalHeight - s) / 2, s, s, 0, 0, N, N);
          for (let qy = 0.86; qy > 0.25; qy -= 0.1) {
            const u = c.toDataURL('image/jpeg', qy);
            if ((u.length - u.indexOf(',') - 1) * 3 / 4 <= PIC_MAX) return res(u);
          }
          rej(new Error('that picture couldn’t be made small enough'));
        };
        img.src = fr.result;
      };
      fr.readAsDataURL(f);
    });
  }
  file.addEventListener('change', () => {
    const f = file.files && file.files[0];
    if (!f) return;
    said('Making it small…');
    encode(f).then((u) => { pic = u; said(''); preview(); }).catch((e) => { said('Not used: ' + e.message, true); file.value = ''; });
  });
  q('.pfnopic').addEventListener('click', () => { pic = ''; file.value = ''; preview(); });
  col.addEventListener('input', () => { colDefault = false; preview(); });
  q('.pfcoldef').addEventListener('click', () => { colDefault = true; said('Back to your default colour when you save.'); });
  nameIn.addEventListener('input', preview);
  q('.pfcancel').addEventListener('click', () => dlg.close());
  q('.pfform').addEventListener('submit', (e) => {
    e.preventDefault();
    const p = people()[me] || {};
    const o = { id: 'p' + Date.now().toString(36) };
    const n = nameIn.value.trim();
    if (n !== (p.name || '')) o.name = n;
    if (colDefault) o.colour = '';
    else if (col.value.toLowerCase() !== (p.colour || '').toLowerCase()) o.colour = col.value.toLowerCase();
    if (pic !== undefined) o.pic = pic;
    if (Object.keys(o).length === 1) { dlg.close(); return; }
    pendingId = o.id;
    said('Saving…');
    ssTabs.act('profile', o).catch(() => { pendingId = null; said('Couldn’t reach Live sync.', true); });
  });

  window.ssProfiles = { avatar, name, colour, edit, decorate, initials };
  take();
})();
