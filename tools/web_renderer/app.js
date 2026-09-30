/* app.js — data load, filters, pagination, card rendering, flag collection. */
(function () {
  const P = window.QXPipeline;
  const C = window.QXCrypto;
  const PAGE_SIZE = 20;
  const GITHUB_OWNER = 'lognjais';
  const GITHUB_REPO = 'questionx';
  const FLAG_KEY = 'qx_flags_v1';
  const BOOKMARK_KEY = 'qx_bookmark_v1';

  // Try diagram images from multiple paths (first hit wins).
  const DIAGRAM_PATHS = [
    '/assets/diagrams/',
    '/scripts/jee/out/full/diagrams_jee_clean/',
    '/scripts/neet/out/full/diagrams_neet_clean/',
  ];

  const state = {
    all: [],        // every question
    filtered: [],   // after filters
    page: 0,
    flags: new Set(JSON.parse(localStorage.getItem(FLAG_KEY) || '[]')),
    byId: new Map(),
    releaseTag: null,
  };

  const $ = (id) => document.getElementById(id);

  // ---- parity banner ----
  function showParity() {
    const res = window.QXParityResults || [];
    const failed = res.filter((r) => !r.ok);
    const el = $('parity');
    if (failed.length === 0) {
      el.className = 'parity ok';
      el.innerHTML = `✔ Pipeline parity: ${res.length}/${res.length} phone tests pass — web output matches the phone.`;
    } else {
      el.className = 'parity fail';
      el.innerHTML = `✗ Pipeline parity: ${failed.length} of ${res.length} FAILED — web may not match phone:<ul>` +
        failed.map((f) => `<li>${f.name}: ${f.msg}</li>`).join('') + '</ul>';
    }
  }

  // ---- GitHub release check ----
  async function checkRelease() {
    const el = $('release-info');
    el.style.display = 'block';
    try {
      const r = await fetch(`https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest`);
      if (!r.ok) throw new Error(r.status);
      const data = await r.json();
      state.releaseTag = data.tag_name;
      const published = new Date(data.published_at).toLocaleDateString('en-IN', {
        day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit',
      });
      el.className = 'release-info';
      el.innerHTML = `📦 Latest release: <b>${data.tag_name}</b> (${published}) · ` +
        `<a href="${data.html_url}" target="_blank">View on GitHub</a>`;
    } catch (e) {
      el.className = 'release-info warn';
      el.innerHTML = `⚠ Could not check GitHub release: ${e.message}`;
    }
  }

  // ---- load ----
  async function load() {
    $('status').textContent = 'Loading question banks …';
    const sources = [];

    // Load JEE (plaintext → .enc fallback via QXCrypto)
    const jee = await C.loadBank('jee');
    if (jee.list.length > 0) sources.push({ name: 'JEE', count: jee.list.length, source: jee.source });
    
    // Load NEET
    const neet = await C.loadBank('neet');
    if (neet.list.length > 0) sources.push({ name: 'NEET', count: neet.list.length, source: neet.source });

    const results = [...jee.list, ...neet.list];

    if (results.length === 0) {
      $('status').textContent = 'ERROR: No question banks found. Did you start serve.sh from the repo root?';
      return;
    }

    state.all = results;
    for (const q of state.all) state.byId.set(q.id, q);

    const sourceInfo = sources.map((s) => `${s.name}: ${s.count.toLocaleString()} (${s.source})`).join(' · ');
    $('status').textContent = `${state.all.length.toLocaleString()} questions — ${sourceInfo}`;

    buildFilters();
    applyFilters();

    // Background: check GitHub release
    checkRelease();
  }

  function uniqSorted(vals) {
    return [...new Set(vals.filter((v) => v != null && v !== ''))].sort();
  }

  function buildFilters() {
    fill('f-exam', uniqSorted(state.all.map((q) => q.exam)));
    fill('f-subject', uniqSorted(state.all.map((q) => q.subject)));
    fill('f-year', uniqSorted(state.all.map((q) => q.year)).sort((a, b) => b - a));
  }
  function fill(id, values) {
    const sel = $(id);
    for (const v of values) {
      const o = document.createElement('option');
      o.value = v; o.textContent = v;
      sel.appendChild(o);
    }
  }

  function applyFilters() {
    const exam = $('f-exam').value;
    const subject = $('f-subject').value;
    const year = $('f-year').value;
    const q = $('f-search').value.trim().toLowerCase();
    const onlyFlagged = $('f-flagged').checked;
    const onlyDiagram = $('f-diagram').checked;
    const onlySolDiagram = $('f-sol-diagram').checked;

    state.filtered = state.all.filter((it) => {
      if (exam && it.exam !== exam) return false;
      if (subject && it.subject !== subject) return false;
      if (year && String(it.year) !== year) return false;
      if (onlyFlagged && !state.flags.has(it.id)) return false;
      if (onlyDiagram && !it.question_svg) return false;
      if (onlySolDiagram && !it.solution_svg) return false;
      if (q) {
        const hay = (it.id + ' ' + (it.question_latex || '') + ' ' +
          (it.options || []).join(' ') + ' ' + (it.solution || '')).toLowerCase();
        if (!hay.includes(q)) return false;
      }
      return true;
    });
    state.page = 0;
    render();
  }

  // ---- render ----
  function render() {
    const total = state.filtered.length;
    const pages = Math.max(1, Math.ceil(total / PAGE_SIZE));
    if (state.page >= pages) state.page = pages - 1;
    const start = state.page * PAGE_SIZE;
    const slice = state.filtered.slice(start, start + PAGE_SIZE);

    $('count').textContent =
      `${total.toLocaleString()} match · page ${state.page + 1}/${pages}` +
      ` · showing ${start + 1}–${start + slice.length}`;
    $('prev').disabled = state.page === 0;
    $('next').disabled = state.page >= pages - 1;

    const list = $('list');
    list.innerHTML = '';
    for (const q of slice) list.appendChild(card(q));
    window.scrollTo(0, 0);
    renderFlagBar();
  }

  function metaChip(label, val) {
    if (val == null || val === '') return '';
    return `<span class="chip"><b>${label}</b> ${val}</span>`;
  }

  // ---- diagram helper: tries multiple paths ----
  function makeDiagramEl(filename) {
    const dwrap = document.createElement('div');
    dwrap.className = 'diagram';
    if (/^<svg/i.test(filename)) {
      dwrap.innerHTML = filename; // legacy inline SVG
      return dwrap;
    }
    const img = document.createElement('img');
    img.alt = filename;
    img.loading = 'lazy';

    // Try paths in order; on error, try the next one
    let pathIdx = 0;
    function tryNext() {
      if (pathIdx < DIAGRAM_PATHS.length) {
        img.src = DIAGRAM_PATHS[pathIdx++] + encodeURIComponent(filename);
      } else {
        dwrap.classList.add('img-missing');
        dwrap.innerHTML = `<span>⚠ diagram not found: ${filename}</span>`;
      }
    }
    img.onerror = tryNext;
    tryNext();
    dwrap.appendChild(img);
    return dwrap;
  }

  function card(q) {
    const el = document.createElement('div');
    el.className = 'card';
    const type = P.typeOf(q.options || [], q.answer_key);
    const flagged = state.flags.has(q.id);

    // header
    const head = document.createElement('div');
    head.className = 'head';
    head.innerHTML =
      `<span class="qid">${q.id}</span>` +
      metaChip('', q.exam) + metaChip('', q.subject) + metaChip('', q.year) +
      metaChip('', q.topic) + metaChip('', q.difficulty) +
      `<span class="chip type">${type}</span>`;
    const flagBtn = document.createElement('button');
    flagBtn.className = 'flagbtn' + (flagged ? ' on' : '');
    flagBtn.textContent = flagged ? '🚩 flagged' : '⚑ flag';
    flagBtn.onclick = () => toggleFlag(q.id, flagBtn, el);
    head.appendChild(flagBtn);
    el.appendChild(head);
    if (flagged) el.classList.add('flagged');

    // question stem
    el.appendChild(labeled('Question', P.renderField(q.question_latex), el));

    // question diagram
    if (q.question_svg) {
      el.appendChild(makeDiagramEl(q.question_svg));
    }

    // options
    if (type === P.QType.mcqSingle || type === P.QType.mcqMulti) {
      const correct = new Set(P.correctOptionIndices(q.answer_key));
      const opts = document.createElement('div');
      opts.className = 'options';
      (q.options || []).forEach((opt, i) => {
        const row = document.createElement('div');
        row.className = 'opt' + (correct.has(i) ? ' correct' : '');
        const tag = document.createElement('span');
        tag.className = 'optlabel';
        tag.textContent = String.fromCharCode(65 + i);
        row.appendChild(tag);
        const r = P.renderField(opt);
        row.appendChild(r.node);
        if (correct.has(i)) row.appendChild(tick());
        opts.appendChild(row);
      });
      el.appendChild(opts);
    }

    // answer
    const ans = document.createElement('div');
    ans.className = 'answer';
    ans.innerHTML = `<b>Answer:</b> ${escapeHtml(P.correctAnswerText(type, q.answer_key))}`;
    el.appendChild(ans);

    // solution
    if (q.solution && q.solution.trim() !== '') {
      el.appendChild(labeled('Solution', P.renderField(q.solution), el));
    }

    // solution diagram
    if (q.solution_svg) {
      const solDiagLabel = document.createElement('div');
      solDiagLabel.className = 'field-label sol-diagram-label';
      solDiagLabel.textContent = 'Solution Diagram';
      el.appendChild(solDiagLabel);
      el.appendChild(makeDiagramEl(q.solution_svg));
    }

    return el;
  }

  // Wrap a rendered field with a label, and badge it if any math fell back.
  function labeled(label, rendered, cardEl) {
    const box = document.createElement('div');
    box.className = 'field';
    const h = document.createElement('div');
    h.className = 'field-label';
    h.textContent = label;
    if (rendered.fallbackCount > 0) {
      const b = document.createElement('span');
      b.className = 'badge-fallback';
      b.textContent = `${rendered.fallbackCount} math fell back`;
      h.appendChild(b);
      cardEl.classList.add('has-fallback');
    }
    box.appendChild(h);
    box.appendChild(rendered.node);
    return box;
  }

  function tick() { const s = document.createElement('span'); s.className = 'tick'; s.textContent = '✓'; return s; }
  function escapeHtml(s) { const d = document.createElement('div'); d.textContent = s; return d.innerHTML; }

  // ---- flags ----
  function toggleFlag(id, btn, cardEl) {
    if (state.flags.has(id)) { state.flags.delete(id); btn.className = 'flagbtn'; btn.textContent = '⚑ flag'; cardEl.classList.remove('flagged'); }
    else { state.flags.add(id); btn.className = 'flagbtn on'; btn.textContent = '🚩 flagged'; cardEl.classList.add('flagged'); }
    localStorage.setItem(FLAG_KEY, JSON.stringify([...state.flags]));
    renderFlagBar();
  }

  function renderFlagBar() {
    $('flag-count').textContent = state.flags.size;
    $('flagbar').style.display = state.flags.size ? 'flex' : 'none';
  }

  async function copyText(txt, btn) {
    try { await navigator.clipboard.writeText(txt); }
    catch (e) { const ta = document.createElement('textarea'); ta.value = txt; document.body.appendChild(ta); ta.select(); document.execCommand('copy'); ta.remove(); }
    const old = btn.textContent; btn.textContent = 'copied ✓'; setTimeout(() => btn.textContent = old, 1200);
  }

  // ---- bookmark / resume ----
  function saveBookmark() {
    const bm = {
      filters: {
        exam: $('f-exam').value,
        subject: $('f-subject').value,
        year: $('f-year').value,
        search: $('f-search').value,
        flagged: $('f-flagged').checked,
        diagram: $('f-diagram').checked,
        solDiagram: $('f-sol-diagram').checked,
      },
      page: state.page,
      scrollY: window.scrollY,
      savedAt: new Date().toISOString(),
    };
    localStorage.setItem(BOOKMARK_KEY, JSON.stringify(bm));
    const btn = $('bm-save');
    const old = btn.textContent;
    btn.textContent = '✓ saved';
    setTimeout(() => btn.textContent = old, 1500);
    updateBookmarkBar();
  }

  function restoreBookmark() {
    const raw = localStorage.getItem(BOOKMARK_KEY);
    if (!raw) return false;
    try {
      const bm = JSON.parse(raw);
      if (bm.filters) {
        $('f-exam').value = bm.filters.exam || '';
        $('f-subject').value = bm.filters.subject || '';
        $('f-year').value = bm.filters.year || '';
        $('f-search').value = bm.filters.search || '';
        $('f-flagged').checked = !!bm.filters.flagged;
        $('f-diagram').checked = !!bm.filters.diagram;
        $('f-sol-diagram').checked = !!bm.filters.solDiagram;
      }
      applyFilters();
      if (typeof bm.page === 'number') {
        state.page = bm.page;
        render();
      }
      if (typeof bm.scrollY === 'number') {
        setTimeout(() => window.scrollTo(0, bm.scrollY), 100);
      }
      return true;
    } catch (e) {
      console.warn('Bookmark restore failed:', e);
      return false;
    }
  }

  function clearBookmark() {
    localStorage.removeItem(BOOKMARK_KEY);
    updateBookmarkBar();
  }

  function updateBookmarkBar() {
    const raw = localStorage.getItem(BOOKMARK_KEY);
    const info = $('bm-info');
    if (raw) {
      try {
        const bm = JSON.parse(raw);
        const when = new Date(bm.savedAt).toLocaleString('en-IN', {
          day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit',
        });
        const filterDesc = [bm.filters.exam, bm.filters.subject, bm.filters.year]
          .filter(Boolean).join(' / ') || 'all';
        info.textContent = `📌 ${filterDesc} · p${(bm.page || 0) + 1} · ${when}`;
      } catch { info.textContent = '📌 saved'; }
    } else {
      info.textContent = 'no bookmark';
    }
  }

  // ---- wire up ----
  window.addEventListener('DOMContentLoaded', () => {
    showParity();
    ['f-exam', 'f-subject', 'f-year'].forEach((id) => $(id).addEventListener('change', applyFilters));
    ['f-flagged', 'f-diagram', 'f-sol-diagram'].forEach((id) => $(id).addEventListener('change', applyFilters));
    let deb; $('f-search').addEventListener('input', () => { clearTimeout(deb); deb = setTimeout(applyFilters, 250); });
    $('prev').onclick = () => { if (state.page > 0) { state.page--; render(); } };
    $('next').onclick = () => { state.page++; render(); };
    $('copy-ids').onclick = (e) => copyText([...state.flags].join('\n'), e.target);
    $('copy-json').onclick = (e) => copyText(JSON.stringify([...state.flags].map((id) => state.byId.get(id)).filter(Boolean), null, 2), e.target);
    $('clear-flags').onclick = () => { if (confirm('Clear all ' + state.flags.size + ' flags?')) { state.flags.clear(); localStorage.setItem(FLAG_KEY, '[]'); renderFlagBar(); applyFilters(); } };
    // Bookmark buttons
    $('bm-save').onclick = saveBookmark;
    $('bm-restore').onclick = restoreBookmark;
    $('bm-clear').onclick = clearBookmark;
    updateBookmarkBar();
    // Load data, then auto-restore bookmark if one exists
    load().then(() => {
      if (localStorage.getItem(BOOKMARK_KEY)) {
        restoreBookmark();
      }
    }).catch((e) => { $('status').textContent = 'ERROR: ' + e.message + ' — did you start serve.sh from the repo root?'; });
  });
})();
