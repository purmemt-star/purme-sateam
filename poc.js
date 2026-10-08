/* Vimeo 진도 PoC — 푸르메 직원교육 LMS
 * 규칙: 실제 재생으로 지나간 고유 구간만 진도로 합산, 첫 학습 중 앞으로 건너뛰기·속도 변경 차단,
 * 이어보기, 80% 도달 시 평가 응시 가능, 이수 후 자유 재생.
 * 저장은 localStorage(서버 대신). 실제 LMS에서는 같은 데이터를 Supabase에 저장하고 서버가 판정한다.
 */
(function () {
  'use strict';

  var THRESHOLD = 0.8;        // 80% 기준
  var MAX_STEP = 1.5;         // 연속 재생으로 인정하는 timeupdate 간격(초)
  var SEEK_TOLERANCE = 2;     // 최대 도달 지점보다 이만큼 앞까지는 허용(초)
  var SAVE_EVERY_MS = 5000;

  var $ = function (id) { return document.getElementById(id); };
  var store = {
    get: function (k) { try { return JSON.parse(localStorage.getItem(k)); } catch (e) { return null; } },
    set: function (k, v) { try { localStorage.setItem(k, JSON.stringify(v)); return true; } catch (e) { return false; } }
  };

  $('host').textContent = location.host || '(로컬 파일)';

  // ---------- 영상 주소 해석 ----------
  function parseVideo(raw) {
    var s = String(raw || '').trim();
    if (!s) return null;
    var m = s.match(/player\.vimeo\.com\/video\/(\d+)(?:\?[^#]*?\bh=([0-9a-f]+))?/i) ||
            s.match(/vimeo\.com\/(?:.*\/)?(\d+)(?:\/([0-9a-f]{6,}))?/i) ||
            s.match(/^(\d+)(?:[\/:]([0-9a-f]{6,}))?$/i);
    if (!m) return null;
    return { id: m[1], hash: m[2] || '' };
  }

  // ---------- 구간 계산 ----------
  function addSegment(segs, a, b) {
    if (!(b > a)) return segs;
    var out = [], placed = false, cur = [a, b];
    segs.forEach(function (s) {
      if (s[1] < cur[0] - 0.25) out.push(s);
      else if (s[0] > cur[1] + 0.25) { if (!placed) { out.push(cur); placed = true; } out.push(s); }
      else cur = [Math.min(s[0], cur[0]), Math.max(s[1], cur[1])];
    });
    if (!placed) out.push(cur);
    return out;
  }
  function total(segs) { return segs.reduce(function (n, s) { return n + (s[1] - s[0]); }, 0); }
  function fmt(t) {
    if (!(t >= 0)) return '–';
    t = Math.floor(t);
    var h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60;
    var mm = (h ? String(m).padStart(2, '0') : String(m)), ss = String(s).padStart(2, '0');
    return (h ? h + ':' : '') + mm + ':' + ss;
  }
  function clock() { return new Date().toTimeString().slice(0, 8); }

  // ---------- 상태 ----------
  var video = null, key = '', player = null;
  var st = null;              // 저장 상태
  var duration = 0, prevT = null, playing = false, current = 0;
  var pending = 0, saveTimer = null, logLines = [];

  function blank() { return { segments: [], last: 0, maxReached: 0, completed: false, skips: 0, rates: 0, savedAt: null }; }

  function log(msg) {
    var line = clock() + '  ' + msg;
    logLines.push(line);
    var li = document.createElement('li');
    li.textContent = line;
    $('log').appendChild(li);
    $('log').scrollTop = $('log').scrollHeight;
  }

  function save(reason) {
    if (!st) return;
    st.last = current;
    if (!navigator.onLine) {
      pending += 1;
      render();
      return;
    }
    st.savedAt = new Date().toISOString();
    if (store.set(key, st)) {
      if (pending) log('대기 중이던 저장 ' + pending + '건을 반영했습니다');
      pending = 0;
      if (reason) log('저장됨 (' + reason + ') · 위치 ' + fmt(st.last) + ' · 시청률 ' + pctText());
    } else {
      pending += 1;
      log('저장 실패: 브라우저 저장소를 쓸 수 없습니다');
    }
    render();
  }

  function pct() { return duration ? Math.min(1, total(st.segments) / duration) : 0; }
  function pctText() { return Math.floor(pct() * 1000) / 10 + '%'; }

  function render() {
    if (!st) return;
    var p = pct();
    $('pct').textContent = pctText();
    $('pctBar').style.width = (p * 100) + '%';
    $('pctSub').textContent = p >= THRESHOLD ? '기준 80% 충족' : '기준 80% · ' + Math.ceil((THRESHOLD - p) * 100) + '%p 남음';
    $('quizState').textContent = st.completed ? '이수 완료 · 자유 재생' : (p >= THRESHOLD ? '응시 가능' : '아직 불가');
    $('btnPass').hidden = !(p >= THRESHOLD && !st.completed);
    $('dur').textContent = fmt(duration);
    $('watched').textContent = fmt(total(st.segments));
    $('maxReached').textContent = fmt(st.maxReached);
    $('resumeAt').textContent = fmt(st.last);
    $('skipCount').textContent = st.skips + '회';
    $('rateCount').textContent = st.rates + '회';
    $('lastSave').textContent = st.savedAt ? new Date(st.savedAt).toTimeString().slice(0, 8) : '–';
    $('queue').textContent = pending + '건';
    $('ruleText').textContent = st.completed
      ? '이수 완료: 건너뛰기와 재생속도 변경이 자유롭습니다.'
      : '첫 학습 중에는 앞으로 건너뛸 수 없고 재생속도가 1.0x로 고정됩니다.';
    // 구간 막대
    var bar = $('segBar');
    bar.innerHTML = '';
    if (duration) {
      st.segments.forEach(function (s) {
        var d = document.createElement('div');
        d.className = 'seg';
        d.style.left = (s[0] / duration * 100) + '%';
        d.style.width = ((s[1] - s[0]) / duration * 100) + '%';
        bar.appendChild(d);
      });
      $('headMark').style.left = (current / duration * 100) + '%';
    }
  }

  // ---------- 플레이어 ----------
  function load(v) {
    video = v;
    key = 'poc:v:' + v.id;
    st = Object.assign(blank(), store.get(key) || {});
    duration = 0; prevT = null; playing = false; current = st.last || 0; pending = 0;
    $('log').innerHTML = ''; logLines = [];
    $('stage').hidden = false; $('logPanel').hidden = false;

    if (player) { try { player.destroy(); } catch (e) {} }
    $('player').innerHTML = '';
    var url = 'https://vimeo.com/' + v.id + (v.hash ? '/' + v.hash : '');
    player = new Vimeo.Player('player', { url: url, speed: false, keyboard: true, title: false, byline: false, portrait: false, dnt: true });

    log('영상 불러오는 중 · ID ' + v.id + (v.hash ? ' (비공개 링크)' : '') + ' · 도메인 ' + (location.host || '로컬 파일'));

    var readyTimer = setTimeout(function () {
      if (!duration) log('10초가 지나도 플레이어가 준비되지 않았습니다 — 영상 화면의 안내 문구를 확인하세요 (비공개 영상이면 해시 포함 링크 필요, 도메인 제한이면 ' + (location.host || '현재 주소') + ' 허용 필요)');
    }, 10000);
    player.ready().then(function () {
      clearTimeout(readyTimer);
      return player.getDuration();
    }).then(function (d) {
      duration = d;
      log('재생 준비 완료 · 길이 ' + fmt(d) + (st.segments.length ? ' · 저장된 시청률 ' + pctText() : ''));
      if (st.last > 1 && st.last < d - 3) {
        return player.setCurrentTime(st.last).then(function () { log('이어보기: ' + fmt(st.last) + ' 지점으로 이동'); });
      }
    }).catch(function (err) {
      log('재생 실패: ' + (err && (err.name + ' ' + (err.message || '')) || '알 수 없는 오류') + ' — 영상 공개 설정과 허용 도메인(' + (location.host || '로컬') + ')을 확인하세요');
    }).then(render);

    player.on('play', function () { playing = true; });
    player.on('pause', function () { playing = false; prevT = null; save('일시정지'); });
    player.on('ended', function () { playing = false; prevT = null; save('재생 종료'); });
    player.on('error', function (e) { log('플레이어 오류: ' + (e && (e.name || e.message) || '')); });

    player.on('timeupdate', function (data) {
      var t = data.seconds;
      if (!duration && data.duration) duration = data.duration;
      if (playing && prevT !== null) {
        var step = t - prevT;
        if (step > 0 && step <= MAX_STEP) {
          st.segments = addSegment(st.segments, prevT, t);
          if (t > st.maxReached && prevT <= st.maxReached + SEEK_TOLERANCE) st.maxReached = t;
        }
      }
      prevT = t; current = t;
      render();
    });

    player.on('seeked', function (data) {
      var t = data.seconds;
      prevT = null;
      if (!st.completed && t > st.maxReached + SEEK_TOLERANCE) {
        st.skips += 1;
        log('앞으로 건너뛰기 차단: ' + fmt(t) + ' → ' + fmt(st.maxReached) + '로 되돌림');
        player.setCurrentTime(st.maxReached).catch(function () {});
      } else {
        log('위치 이동: ' + fmt(t));
      }
      current = t;
      render();
    });

    player.on('playbackratechange', function (data) {
      if (!st.completed && data.playbackRate !== 1) {
        st.rates += 1;
        log('재생속도 변경 차단: ' + data.playbackRate + 'x → 1.0x');
        player.setPlaybackRate(1).catch(function () { log('속도 되돌리기 실패 (요금제·설정 확인 필요)'); });
        render();
      }
    });

    clearInterval(saveTimer);
    saveTimer = setInterval(function () { if (playing) save(); }, SAVE_EVERY_MS);
    render();
  }

  // ---------- 화면 이벤트 ----------
  var passBtn = document.createElement('button');
  passBtn.type = 'button'; passBtn.className = 'btn primary'; passBtn.id = 'btnPass'; passBtn.hidden = true;
  passBtn.textContent = '평가 통과로 이수 처리 (가정)';
  document.querySelector('.actions').prepend(passBtn);
  passBtn.addEventListener('click', function () { st.completed = true; log('이수 처리: 이제 자유 재생'); save('이수'); });

  $('loadForm').addEventListener('submit', function (e) {
    e.preventDefault();
    var v = parseVideo($('videoInput').value);
    if (!v) { alertInline('영상 링크나 숫자 ID를 확인해 주세요.'); return; }
    history.replaceState(null, '', '?v=' + v.id + (v.hash ? '/' + v.hash : ''));
    load(v);
  });
  function alertInline(msg) {
    var h = document.querySelector('.hint');
    h.textContent = msg; h.style.color = 'var(--danger-ink)';
  }

  $('btnSave').addEventListener('click', function () { save('수동'); });
  $('btnReload').addEventListener('click', function () { save('새로고침 전'); location.reload(); });
  $('btnReset').addEventListener('click', function () {
    if (!st) return;
    st = blank(); store.set(key, st); current = 0;
    if (player) player.setCurrentTime(0).catch(function () {});
    log('이 영상의 기록을 초기화했습니다');
    render();
  });
  $('btnCopy').addEventListener('click', function () {
    var env = $('envSel').value;
    var checks = Array.prototype.map.call(document.querySelectorAll('#checks li'), function (li) {
      return (li.querySelector('input').checked ? '[O] ' : '[ ] ') + li.querySelector('strong').textContent;
    });
    var text = ['Vimeo 진도 PoC 결과', '환경: ' + env + ' · ' + navigator.userAgent, '도메인: ' + (location.host || '로컬'),
      '시청률: ' + (st ? pctText() : '–') + ' · 길이 ' + fmt(duration) + ' · 건너뛰기 차단 ' + (st ? st.skips : 0) + '회 · 속도 차단 ' + (st ? st.rates : 0) + '회',
      '', '[점검표]'].concat(checks, ['', '[이벤트]'], logLines).join('\n');
    (navigator.clipboard ? navigator.clipboard.writeText(text) : Promise.reject()).then(
      function () { $('btnCopy').textContent = '복사됨'; setTimeout(function () { $('btnCopy').textContent = '결과 복사'; }, 1500); },
      function () { window.prompt('아래 내용을 복사하세요', text); });
  });

  document.addEventListener('visibilitychange', function () {
    if (!st) return;
    if (document.hidden) { save('탭 숨김'); log('탭 전환·화면 꺼짐 감지'); }
    else log('탭 복귀');
  });
  window.addEventListener('pagehide', function () { save(); });
  window.addEventListener('offline', function () { $('offline').hidden = false; if (st) log('네트워크 끊김'); });
  window.addEventListener('online', function () { $('offline').hidden = true; if (st) { log('네트워크 복구'); save('재연결'); } });
  $('offline').hidden = navigator.onLine;

  // ---------- 점검표 ----------
  var CHECKS = [
    ['영상이 재생된다', 'Vimeo 허용 도메인에 현재 도메인이 있어야 함'],
    ['재생바를 앞으로 끌면 원래 위치로 돌아온다', '이벤트 기록에 "건너뛰기 차단"이 남음'],
    ['키보드 → 키로도 앞으로 건너뛸 수 없다', '플레이어를 클릭한 뒤 → 키'],
    ['재생속도를 바꿀 수 없다', '속도 메뉴가 없거나, 바꿔도 1.0x로 돌아옴'],
    ['이미 본 구간을 다시 봐도 시청률이 늘지 않는다', '뒤로 돌려 다시 재생'],
    ['시청률 80%에서 "응시 가능"으로 바뀐다', ''],
    ['새로고침 후 마지막 위치부터 이어진다', '"새로고침 후 이어보기 시험" 버튼'],
    ['탭을 바꿨다 돌아와도 기록이 유지된다', '다른 탭 30초 후 복귀'],
    ['네트워크를 끊었다 연결하면 자동 저장된다', '와이파이 끄기 → 재생 → 켜기'],
    ['이수 처리 후에는 자유롭게 건너뛸 수 있다', '"평가 통과로 이수 처리" 후 재생바 이동'],
    ['허용하지 않은 주소에서는 재생되지 않는다', 'Vimeo 도메인 제한을 켠 뒤, 다른 주소에서 같은 영상 열기']
  ];
  function renderChecks() {
    var env = $('envSel').value, saved = store.get('poc:checks:' + env) || {};
    var ul = $('checks'); ul.innerHTML = '';
    CHECKS.forEach(function (c, i) {
      var li = document.createElement('li');
      var id = 'chk' + i;
      li.innerHTML = '<input type="checkbox" id="' + id + '"><label for="' + id + '"><strong></strong><span class="how"></span></label>';
      li.querySelector('strong').textContent = c[0];
      li.querySelector('.how').textContent = c[1];
      var box = li.querySelector('input');
      box.checked = !!saved[i];
      box.addEventListener('change', function () { saved[i] = box.checked; store.set('poc:checks:' + env, saved); });
      ul.appendChild(li);
    });
  }
  $('envSel').addEventListener('change', renderChecks);
  var ua = navigator.userAgent;
  $('envSel').value = /SamsungBrowser/.test(ua) ? '가로형 태블릿 · Samsung Internet'
    : /Edg\//.test(ua) ? 'PC · Edge'
    : /iPad|Macintosh.*Mobile|Version\/.*Safari/.test(ua) && !/Chrome/.test(ua) ? 'iPad · Safari' : 'PC · Chrome';
  renderChecks();

  // ---------- 주소로 바로 열기 ----------
  var q = new URLSearchParams(location.search).get('v');
  if (q) { var v0 = parseVideo(q); if (v0) { $('videoInput').value = q; load(v0); } }
})();
