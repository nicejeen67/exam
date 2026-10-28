/* =====================================================================
 *  AI EXAM · GitHub Pages용 공통 모듈 (학교 서버의 /assets/auth.js 대체)
 *  ---------------------------------------------------------------------
 *  · 각 페이지가 호출하던 서버 주소(AIEXAM_API/...)를 Supabase DB 함수(RPC) 호출로 바꿔 줍니다.
 *    → 페이지 본문 코드는 거의 그대로 두고 이 파일만 교체하는 방식입니다.
 *  · 로그인 토큰은 sessionStorage('aiexam_token')에 보관합니다(창을 닫으면 로그아웃).
 *  · Supabase 주소/키는 config.js 의 window.AIEXAM_CONFIG 에서 읽습니다.
 * ===================================================================== */
(function () {
  'use strict';

  var API = 'supabase-rpc://aiexam';
  window.AIEXAM_API = API;

  // 이 스크립트 위치로 사이트 기준 경로 계산 (같은 폴더)
  var me = document.currentScript && document.currentScript.src;
  var BASE = me ? me.replace(/auth\.js(\?.*)?$/, '') : './';
  window.AIEXAM_BASE = BASE;

  var cfg = window.AIEXAM_CONFIG || {};
  var SB_URL = String(cfg.SUPABASE_URL || '').trim().replace(/\/+$/, '');
  var SB_KEY = String(cfg.SUPABASE_ANON_KEY || '').trim();
  var READY = !!SB_URL && !!SB_KEY && SB_URL.indexOf('YOUR-PROJECT') < 0 && SB_KEY.indexOf('YOUR-') < 0;

  var TOKEN_KEY = 'aiexam_token';
  var USER_KEY = 'aiexam_user';
  function ssGet(k) { try { return sessionStorage.getItem(k); } catch (e) { return null; } }
  function ssSet(k, v) { try { if (v == null) sessionStorage.removeItem(k); else sessionStorage.setItem(k, v); } catch (e) { /* 무시 */ } }

  /* ---------------- Supabase RPC ---------------- */
  function RpcError(message, expired) { var e = new Error(message); e.expired = !!expired; return e; }

  async function rpc(fn, params) {
    if (!READY) throw RpcError('Supabase 설정이 필요합니다. config.js 에 주소와 키를 입력해 주세요.');
    var headers = { 'Content-Type': 'application/json', apikey: SB_KEY };
    if (SB_KEY.indexOf('eyJ') === 0) headers.Authorization = 'Bearer ' + SB_KEY;
    var res;
    try {
      res = await fetchOriginal(SB_URL + '/rest/v1/rpc/' + fn, { method: 'POST', headers: headers, body: JSON.stringify(params || {}) });
    } catch (e) {
      throw RpcError('서버에 연결할 수 없습니다. 인터넷 연결을 확인해 주세요.');
    }
    var body = null;
    try { body = await res.json(); } catch (e) { body = null; }
    if (!res.ok) {
      var code = body && body.code;
      if (code === '28000') throw RpcError((body && body.message) || '다시 로그인해 주세요.', true);
      if (code === 'PGRST202') throw RpcError('DB 함수가 없습니다. Supabase SQL Editor에서 supabase/aiexam_schema.sql 을 실행했는지 확인해 주세요.');
      if (res.status === 401) throw RpcError('Supabase 키가 올바르지 않습니다. config.js 를 확인해 주세요.');
      throw RpcError((body && body.message) || ('요청이 실패했습니다. (' + res.status + ')'));
    }
    if (body && typeof body === 'object' && !Array.isArray(body) && body.error) throw RpcError(body.error);
    return body;
  }
  window.aiexamRpc = rpc;

  function token() { return ssGet(TOKEN_KEY) || ''; }
  window.aiexamGetToken = token;

  function goLogin() {
    ssSet(TOKEN_KEY, null); ssSet(USER_KEY, null);
    location.replace(BASE + 'auth.html?redirect=' + encodeURIComponent(location.pathname + location.search));
  }

  /* ---------------- 기존 서버 API 흉내 (fetch 가로채기) ---------------- */
  function json(data, status) {
    return new Response(JSON.stringify(data), { status: status || 200, headers: { 'Content-Type': 'application/json' } });
  }
  function formToObj(body) {
    var o = {};
    if (body && typeof FormData !== 'undefined' && body instanceof FormData) body.forEach(function (v, k) { o[k] = v; });
    else if (typeof body === 'string') { try { o = JSON.parse(body); } catch (e) { /* 무시 */ } }
    return o;
  }
  function fileToBase64(file) {
    return new Promise(function (resolve, reject) {
      var r = new FileReader();
      r.onload = function () { resolve(String(r.result).split(',')[1] || ''); };
      r.onerror = function () { reject(new Error('파일을 읽을 수 없습니다.')); };
      r.readAsDataURL(file);
    });
  }
  function b64ToBlob(b64, mime) {
    var bin = atob(b64 || ''); var arr = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
    return new Blob([arr], { type: mime || 'application/octet-stream' });
  }
  function num(v) { var n = parseInt(v, 10); return isNaN(n) ? null : n; }

  async function handle(url, opts) {
    var u = new URL(url.replace(API, 'http://local'));
    var path = u.pathname.replace(/\/+$/, '');
    var method = (opts.method || 'GET').toUpperCase();
    var q = u.searchParams;
    var f = formToObj(opts.body);
    var t = token();
    var m;

    // 회원
    if (path === '/subjects') return json(await rpc('ax_subjects', {}));
    if (path === '/login' && method === 'POST') return json(await rpc('ax_login', { p_username: f.username, p_password: f.password }));
    if (path === '/register' && method === 'POST') {
      return json(await rpc('ax_register', { p: { username: f.username, password: f.password, name: f.name, role: f.role, subject_id: f.subject_id || null } }));
    }
    if (path === '/me') return json(await rpc('ax_me', { p_token: t }));

    // 교안
    if (path === '/materials' && method === 'GET') {
      return json(await rpc('ax_materials_list', { p_token: t, p_subject: q.get('subject_id'), p_kind: q.get('kind') || null }));
    }
    if (path === '/materials' && method === 'POST') {
      var file = f.file;
      if (!file) return json({ detail: '파일이 없습니다.' }, 400);
      if (file.size > 8 * 1024 * 1024) return json({ detail: '교안 파일은 8MB 이하만 업로드할 수 있습니다.' }, 400);
      return json(await rpc('ax_material_upload', { p_token: t, p: {
        subject_id: f.subject_id, week_no: num(f.week_no), kind: f.kind || 'lecture', title: f.title,
        filename: file.name, mime: file.type, data_b64: await fileToBase64(file) } }));
    }
    if ((m = path.match(/^\/materials\/(\d+)\/download$/))) {
      var d = await rpc('ax_material_download', { p_token: t, p_id: num(m[1]) });
      return new Response(b64ToBlob(d.data_b64, d.mime), { status: 200, headers: { 'Content-Type': d.mime || 'application/octet-stream' } });
    }
    if ((m = path.match(/^\/materials\/(\d+)$/)) && method === 'DELETE') return json(await rpc('ax_material_delete', { p_token: t, p_id: num(m[1]) }));

    // 기출문제
    if (path === '/exam-questions/summary') return json(await rpc('ax_questions_summary', { p_token: t, p_subject: q.get('subject_id') }));
    if (path === '/exam-questions' && method === 'GET') {
      return json(await rpc('ax_questions_list', { p_token: t, p_subject: q.get('subject_id'), p_week: num(q.get('week_no')) }));
    }
    if (path === '/exam-questions' && method === 'POST') {
      return json(await rpc('ax_question_add', { p_token: t, p: {
        subject_id: f.subject_id, week_no: num(f.week_no), question: f.question, option1: f.option1, option2: f.option2,
        option3: f.option3, option4: f.option4, option5: f.option5, answer: num(f.answer), explanation: f.explanation } }));
    }

    // 시험 기록 → 학생 폴더
    if (path === '/exam-attempts' && method === 'POST') {
      var qs = []; try { qs = JSON.parse(f.questions_json || '[]'); } catch (e) { qs = []; }
      return json(await rpc('ax_attempt_save', { p_token: t, p: {
        subject_id: f.subject_id, title: f.title, total_questions: num(f.total_questions),
        correct_count: num(f.correct_count), score: num(f.score), questions: qs } }));
    }
    if (path === '/exam-attempts' && method === 'GET') {
      return json(await rpc('ax_attempts_list', { p_token: t, p_subject: q.get('subject_id'), p_scope: q.get('scope') || 'mine' }));
    }
    if ((m = path.match(/^\/exam-attempts\/(\d+)$/))) return json(await rpc('ax_file_get', { p_token: t, p_id: num(m[1]) }));

    // 관리자
    if ((m = path.match(/^\/admin\/(pending-professors|professors|students)$/))) return json(await rpc('ax_admin_users', { p_token: t, p_kind: m[1] }));
    if (path === '/admin/approve') return json(await rpc('ax_admin_approve', { p_token: t, p_user_id: num(f.user_id), p_subject: f.subject_id }));
    if (path === '/admin/reject') return json(await rpc('ax_admin_reject', { p_token: t, p_user_id: num(f.user_id) }));
    if ((m = path.match(/^\/admin\/users\/(\d+)$/)) && method === 'DELETE') return json(await rpc('ax_admin_delete_user', { p_token: t, p_user_id: num(m[1]) }));
    if (path === '/admin/terminal-token') return json({ detail: 'GitHub 버전에서는 서버 터미널 기능을 사용할 수 없습니다.' }, 400);

    return json({ detail: '지원하지 않는 요청입니다: ' + method + ' ' + path }, 404);
  }

  var fetchOriginal = window.fetch.bind(window);
  window.fetch = function (input, opts) {
    var url = typeof input === 'string' ? input : (input && input.url) || '';
    if (url.indexOf(API) === 0) {
      return handle(url, opts || {}).catch(function (e) {
        if (e.expired) { setTimeout(goLogin, 50); return json({ detail: e.message }, 401); }
        return json({ detail: e.message }, 400);
      });
    }
    return fetchOriginal(input, opts);
  };

  /* ---------------- 로그인 확인 · 사용자 표시 ---------------- */
  window.aiexamRequireAuth = async function (roles) {
    if (!token()) { goLogin(); return null; }
    try {
      var user = await rpc('ax_me', { p_token: token() });
      ssSet(USER_KEY, JSON.stringify(user));
      if (roles && roles.length && roles.indexOf(user.role) < 0) {
        alert('이 페이지에 접근할 권한이 없습니다.');
        location.replace(BASE + 'index.html');
        return null;
      }
      window.aiexamCurrentUser = user;
      return user;
    } catch (e) {
      if (e.expired) { goLogin(); return null; }
      var ov = document.getElementById('authLoadingOverlay');
      if (ov) ov.innerHTML = '<div style="text-align:center;line-height:1.8;padding:20px">' + e.message.replace(/</g, '&lt;') +
        '<br><a href="' + BASE + 'auth.html" style="color:#C9A227">로그인 화면으로</a></div>';
      return null;
    }
  };

  window.aiexamLogout = async function () {
    var t = token();
    ssSet(TOKEN_KEY, null); ssSet(USER_KEY, null);
    try { await rpc('ax_logout', { p_token: t }); } catch (e) { /* 무시 */ }
    location.href = BASE + 'auth.html';
  };

  var ROLE_LABEL = { student: '학생', professor: '교수', admin: '관리자' };
  window.aiexamRenderUserBar = function (el, user) {
    if (!el || !user) return;
    el.innerHTML = '';
    el.style.display = 'flex';
    el.style.alignItems = 'center';
    el.style.gap = '6px';
    var name = document.createElement('span');
    name.className = 'aiexam-userbar-name';
    name.textContent = user.name + ' (' + user.username + ' · ' + (ROLE_LABEL[user.role] || user.role) + ')';
    el.appendChild(name);
    var folder = document.createElement('a');
    folder.href = BASE + 'my.html';
    folder.className = 'aiexam-userbar-logout';
    folder.style.textDecoration = 'none';
    folder.textContent = '📁 내 폴더';
    folder.title = user.username + ' 폴더 (시험 기록 · 생성한 모의고사)';
    el.appendChild(folder);
    var out = document.createElement('button');
    out.type = 'button';
    out.className = 'aiexam-userbar-logout';
    out.textContent = '로그아웃';
    out.onclick = window.aiexamLogout;
    el.appendChild(out);
  };

  /* ---------------- 생성한 모의고사를 학생 폴더에 저장 ---------------- */
  function currentSubject() { return (typeof SUBJECT_ID !== 'undefined' && SUBJECT_ID) || ''; }
  window.aiexamSaveGenerated = async function (title, subtitle, questions) {
    try {
      var qs = (questions || []).map(function (x) {
        return { question: x.question, options: x.options, answer: x.answer, explanation: x.explanation };
      });
      var r = await rpc('ax_generated_save', { p_token: token(), p: { subject_id: currentSubject(), title: title, subtitle: subtitle, questions: qs } });
      if (typeof showToast === 'function') showToast('생성한 모의고사를 내 폴더(' + r.path.split('/').slice(0, 3).join('/') + ')에 저장했습니다.', '📁');
      return r;
    } catch (e) {
      console.warn('[aiexam] 생성 모의고사 저장 실패', e);
      if (typeof showToast === 'function') showToast('모의고사를 폴더에 저장하지 못했습니다: ' + e.message, '⚠️');
      return null;
    }
  };
  window.aiexamOpenGenerated = function (title, subtitle, questions) {
    window.aiexamSaveGenerated(title, subtitle, questions);
    return window.openOfficialExamPopup(title, subtitle, questions);
  };

  /* 내 폴더에서 [다시 풀기] → 과목 페이지?retake=파일번호 */
  window.addEventListener('load', function () {
    var id = new URLSearchParams(location.search).get('retake');
    if (!id || !currentSubject()) return;
    var tries = 0;
    var timer = setInterval(async function () {
      tries++;
      var ov = document.getElementById('authLoadingOverlay');
      var ready = typeof window.openOfficialExamPopup === 'function' && (!ov || ov.style.display === 'none');
      if (!ready && tries < 60) return;
      clearInterval(timer);
      if (!ready) return;
      try {
        var f = await rpc('ax_file_get', { p_token: token(), p_id: parseInt(id, 10) });
        var qs = (f.questions || []).map(function (x, i) {
          return { id: 'retake-' + i, question: x.question, options: x.options, answer: x.answer, explanation: x.explanation };
        });
        history.replaceState(null, '', location.pathname);
        window.openOfficialExamPopup(f.title.replace(/\s*\(다시 풀기\)$/, '') + ' (다시 풀기)', f.subtitle || f.subject_name, qs);
      } catch (e) {
        alert('모의고사를 불러오지 못했습니다: ' + e.message);
      }
    }, 250);
  });

  /* PDF·Word 텍스트 추출 라이브러리 (필요할 때만 CDN에서 불러옴) */
  var libsPromise = null;
  function loadScript(src) {
    return new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = src; s.onload = resolve; s.onerror = function () { reject(new Error(src + ' 로드 실패')); };
      document.head.appendChild(s);
    });
  }
  window.aiexamEnsureDocumentLibraries = function () {
    if (libsPromise) return libsPromise;
    var cdn = 'https://cdnjs.cloudflare.com/ajax/libs/';
    libsPromise = Promise.all([
      typeof window.pdfjsLib !== 'undefined' ? null : loadScript(cdn + 'pdf.js/3.11.174/pdf.min.js').then(function () {
        if (window.pdfjsLib) window.pdfjsLib.GlobalWorkerOptions.workerSrc = cdn + 'pdf.js/3.11.174/pdf.worker.min.js';
      }),
      typeof window.mammoth !== 'undefined' ? null : loadScript(cdn + 'mammoth/1.6.0/mammoth.browser.min.js')
    ]).catch(function (e) { libsPromise = null; console.warn(e); });
    return libsPromise;
  };
})();
