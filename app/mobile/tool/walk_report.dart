// 歩行ログを人が読める形にする（判断の一覧と理由）。
//
//   cd app/mobile
//   dart run tool/walk_report.dart <歩行ログ.jsonl> [出力.md]
//   dart run tool/walk_report.dart <歩行ログ.jsonl> 出力.html   （軌道の図と時刻のつまみつき）
//
// HTML の軌道は出発点からのメートルで描く（緯度経度は書き出さない）。ただし道の形は分かるので、
// 自宅付近で録ったログの HTML は人に渡さない・コミットしない。
//
// 歩行ログには判断（LogDecision）は入っていない。engine は同じログを流せば同じ判断になる
// （決定論）ので、ここで engine にもう一度流して判断を取り出す。端末で動いた判断と同じになる。
// 緯度経度は出さない（自宅付近のログでも、出力をそのまま人に見せられるように）。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:engine/engine.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('使い方: dart run tool/walk_report.dart <歩行ログ.jsonl> [出力.md]');
    exit(64);
  }
  final input = File(args[0]);
  final reasons = _reasonText();
  final names = <String, String>{};
  final rows = <Map<String, dynamic>>[];
  for (final line in input.readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    try {
      rows.add(jsonDecode(line) as Map<String, dynamic>);
    } on FormatException {
      // 壊れた行は飛ばす
    }
  }
  if (rows.isEmpty) {
    stderr.writeln('行がありません');
    exit(1);
  }

  final engine = Engine();
  final t0 = rows.first['t_ms'] as int;
  final decisions = <Decision>[];
  var sensors = 0, tiles = 0, emptyTiles = 0, alerts = 0, finished = 0;
  var lastSpeed = 0.0;
  var maxSpeed = 0.0;
  // 軌道（HTML 用）。出発点からの東西・南北のメートルだけを持ち、緯度経度は書き出さない。
  final track = <_Pt>[];
  final landmarkMarks = <String, _Mark>{};
  double? lat0, lon0;
  (double, double) local(double lat, double lon) {
    lat0 ??= lat;
    lon0 ??= lon;
    const mPerDegLat = 111320.0;
    final mPerDegLon = mPerDegLat * math.cos(lat0! * math.pi / 180);
    return ((lon - lon0!) * mPerDegLon, (lat - lat0!) * mPerDegLat);
  }

  for (final r in rows) {
    final EngineEvent e;
    try {
      e = eventFromJson(r);
    } catch (_) {
      continue; // engine の知らない行（版の違いなど）
    }
    switch (e) {
      case SensorFrame():
        sensors++;
        lastSpeed = e.speedMps ?? 0;
        if (lastSpeed > maxSpeed) maxSpeed = lastSpeed;
        final (x, y) = local(e.lat, e.lon);
        track.add(_Pt(e.tMs, x, y, e.gazeAzDeg));
      case TilesLoaded():
        tiles++;
        final t = e.tile;
        if (t.landmarks.isEmpty && t.crossings.isEmpty && t.events.isEmpty) {
          emptyTiles++;
        }
        for (final lm in t.landmarks) {
          names[lm.id] = lm.name;
          final (x, y) = local(lm.lat, lm.lon);
          landmarkMarks[lm.id] = _Mark(
            lm.name,
            x,
            y,
            lm.radiusM ?? const EngineConfig().defaultRadiusM,
            lm.kind,
          );
        }
      case AlertReceived():
        alerts++;
      case TtsFinished():
        finished++;
      default:
        break;
    }
    for (final c in engine.handle(e)) {
      if (c is LogDecision) decisions.add(c.decision);
    }
  }

  String clock(int t) {
    final s = (t - t0) ~/ 1000;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  String target(String? id) {
    if (id == null) return '';
    final n = names[id];
    return n == null ? id : '$n（$id）';
  }

  final speaks = decisions.where((d) => d.kind == 'speak').toList();
  final counts = <String, int>{};
  for (final d in decisions) {
    counts[d.reason] = (counts[d.reason] ?? 0) + 1;
  }

  final out = StringBuffer()
    ..writeln('# 歩行ログの判断（${input.uri.pathSegments.last}）')
    ..writeln()
    ..writeln('engine に歩行ログをもう一度流して取り出した判断です（端末で動いた判断と同じ）。位置（緯度経度）は出していません。')
    ..writeln()
    ..writeln('## まとめ')
    ..writeln()
    ..writeln(
      '- 長さ：${clock(rows.last['t_ms'] as int)}（センサー $sensors 行、最高 ${maxSpeed.toStringAsFixed(1)} m/s）',
    )
    ..writeln('- 取ったタイル：$tiles 枚（うち空 $emptyTiles 枚）')
    ..writeln('- 話した：${speaks.length} 回　話し終えた通知：$finished 回　警報：$alerts 件')
    ..writeln()
    ..writeln('## 話したこと')
    ..writeln()
    ..writeln('| 時刻 | 理由 | 対象 | 話した文 |')
    ..writeln('| :-- | :-- | :-- | :-- |');
  for (final d in speaks) {
    out.writeln(
      '| ${clock(d.tMs)} | ${reasons[d.reason] ?? d.reason} | ${target(d.targetId)} | ${_cell(d.text ?? '')} |',
    );
  }
  out
    ..writeln()
    ..writeln('## 判断の数（理由ごと）')
    ..writeln()
    ..writeln('| 理由コード | 説明 | 回数 |')
    ..writeln('| :-- | :-- | --: |');
  final sorted = counts.entries.toList()..sort((a, b) => b.value - a.value);
  for (final e in sorted) {
    out.writeln('| `${e.key}` | ${reasons[e.key] ?? ''} | ${e.value} |');
  }
  out
    ..writeln()
    ..writeln('## すべての判断（時刻順）')
    ..writeln()
    ..writeln('| 時刻 | 種類 | 理由 | 対象 |')
    ..writeln('| :-- | :-- | :-- | :-- |');
  for (final d in decisions) {
    out.writeln(
      '| ${clock(d.tMs)} | ${d.kind} | ${reasons[d.reason] ?? d.reason}（`${d.reason}`） | ${target(d.targetId)} |',
    );
  }

  if (args.length > 1 && args[1].endsWith('.html')) {
    File(args[1]).writeAsStringSync(
      _html(
        title: input.uri.pathSegments.last,
        summaryMd: out.toString(),
        track: track,
        landmarks: landmarkMarks,
        decisions: decisions,
        reasons: reasons,
        names: names,
        t0: t0,
        speeches: speaks.length,
      ),
    );
    stdout.writeln(
      '書き出しました: ${args[1]}（話した ${speaks.length} 回・判断 ${decisions.length} 件）',
    );
  } else if (args.length > 1) {
    File(args[1]).writeAsStringSync(out.toString());
    stdout.writeln(
      '書き出しました: ${args[1]}（話した ${speaks.length} 回・判断 ${decisions.length} 件）',
    );
  } else {
    stdout.write(out.toString());
  }
}

String _cell(String s) => s.replaceAll('|', '／').replaceAll('\n', ' ');

/// 軌道の1点（出発点からの東 x・北 y メートル）。
class _Pt {
  const _Pt(this.tMs, this.x, this.y, this.gaze);
  final int tMs;
  final double x, y, gaze;
}

/// ランドマーク（出発点からのメートル、話す範囲の半径）。
class _Mark {
  const _Mark(this.name, this.x, this.y, this.radiusM, this.kind);
  final String name, kind;
  final double x, y, radiusM;
}

String _html({
  required String title,
  required String summaryMd,
  required List<_Pt> track,
  required Map<String, _Mark> landmarks,
  required List<Decision> decisions,
  required Map<String, String> reasons,
  required Map<String, String> names,
  required int t0,
  required int speeches,
}) {
  double r1(double v) => (v * 10).roundToDouble() / 10;
  // 軌道は1秒に1点で十分（多すぎると重い）
  final pts = <List<num>>[];
  var lastSec = -1;
  for (final p in track) {
    final s = (p.tMs - t0) ~/ 1000;
    if (s == lastSec) continue;
    lastSec = s;
    pts.add([s, r1(p.x), r1(p.y), p.gaze.round()]);
  }
  final data = {
    'track': pts,
    'landmarks': [
      for (final e in landmarks.entries)
        {
          'id': e.key,
          'name': e.value.name,
          'x': r1(e.value.x),
          'y': r1(e.value.y),
          'r': e.value.radiusM,
          'kind': e.value.kind,
        },
    ],
    'decisions': [
      for (final d in decisions)
        {
          's': ((d.tMs - t0) / 1000).floor(),
          'kind': d.kind,
          'reason': d.reason,
          'label': reasons[d.reason] ?? d.reason,
          'target': d.targetId == null
              ? ''
              : (names[d.targetId] ?? d.targetId),
          'text': d.text ?? '',
        },
    ],
  };
  final json = jsonEncode(data).replaceAll('</', '<\\/');
  final esc = const HtmlEscape();
  return '''<!doctype html>
<html lang="ja"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>歩行の振り返り</title>
<style>
:root{--bg:#f7f7f5;--fg:#1d1d1b;--mute:#6b6b66;--line:#d8d8d2;--card:#fff;--track:#9a9a92;--done:#2563eb;--speak:#d9480f;--search:#7c3aed;--lm:#0f766e}
@media (prefers-color-scheme:dark){:root{--bg:#161615;--fg:#ececea;--mute:#9a9a94;--line:#33332f;--card:#1f1f1d;--track:#5c5c56;--done:#60a5fa;--speak:#fb923c;--search:#a78bfa;--lm:#2dd4bf}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 system-ui,"Hiragino Sans","Yu Gothic UI",sans-serif}
main{max-width:1100px;margin:0 auto;padding:16px}
h1{font-size:18px;margin:0 0 4px}.sub{color:var(--mute);margin:0 0 12px}
.grid{display:grid;grid-template-columns:minmax(0,3fr) minmax(0,2fr);gap:16px}
@media (max-width:800px){.grid{grid-template-columns:1fr}}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px}
svg{width:100%;height:auto;display:block;touch-action:none}
.ctl{display:flex;gap:8px;align-items:center;margin-top:8px}
.ctl input{flex:1}.ctl button{border:1px solid var(--line);background:var(--bg);color:var(--fg);border-radius:6px;padding:4px 10px;cursor:pointer}
#now{font-variant-numeric:tabular-nums;min-width:48px}
#say{min-height:3.2em;margin-top:8px;padding:8px;border-radius:6px;background:var(--bg)}
.legend{display:flex;flex-wrap:wrap;gap:12px;color:var(--mute);font-size:12px;margin-top:6px}
.legend i{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:4px;vertical-align:middle}
table{width:100%;border-collapse:collapse;font-size:13px}td,th{border-bottom:1px solid var(--line);padding:4px 6px;text-align:left;vertical-align:top}
th{color:var(--mute);font-weight:600}tr.cur{background:color-mix(in srgb,var(--done) 14%,transparent)}
tr[data-s]{cursor:pointer}.list{max-height:520px;overflow:auto}
.k-speak td:nth-child(2){color:var(--speak);font-weight:600}.k-search td:nth-child(2),.k-answer td:nth-child(2){color:var(--search)}
</style></head><body><main>
<h1>歩行の振り返り</h1>
<p class="sub">${esc.convert(title)}・話した $speeches 回・判断 ${decisions.length} 件。engine に歩行ログを流し直した判断です。地図は出発点からのメートル（北が上）で、緯度経度は入れていません。</p>
<div class="grid">
<section class="card">
<svg id="map" role="img" aria-label="歩いた道と、話した場所"></svg>
<div class="ctl"><button id="play" type="button">再生</button><input id="t" type="range" min="0" value="0" aria-label="時刻"><span id="now">00:00</span></div>
<div id="say" aria-live="polite"></div>
<div class="legend"><span><i style="background:var(--track)"></i>歩いた道</span><span><i style="background:var(--speak)"></i>話した</span><span><i style="background:var(--search)"></i>B の計測</span><span><i style="border:2px solid var(--lm)"></i>ランドマークと話す範囲</span></div>
</section>
<section class="card list"><table><thead><tr><th>時刻</th><th>判断</th><th>対象・話した文</th></tr></thead><tbody id="rows"></tbody></table></section>
</div>
<details class="card" style="margin-top:16px"><summary>Markdown の一覧</summary><pre style="white-space:pre-wrap">${esc.convert(summaryMd)}</pre></details>
</main>
<script>
const D=$json;
const T=D.track, svg=document.getElementById('map'), NS='http://www.w3.org/2000/svg';
const fmt=s=>String(Math.floor(s/60)).padStart(2,'0')+':'+String(s%60).padStart(2,'0');
const xs=T.map(p=>p[1]).concat(D.landmarks.flatMap(l=>[l.x-l.r,l.x+l.r]));
const ys=T.map(p=>p[2]).concat(D.landmarks.flatMap(l=>[l.y-l.r,l.y+l.r]));
const pad=30, minX=Math.min(...xs)-pad, maxX=Math.max(...xs)+pad, minY=Math.min(...ys)-pad, maxY=Math.max(...ys)+pad;
svg.setAttribute('viewBox',minX+' '+(-maxY)+' '+(maxX-minX)+' '+(maxY-minY));
const k=(maxX-minX)/600; // 画面上の大きさをそろえる係数
function el(n,a,p){const e=document.createElementNS(NS,n);for(const x in a)e.setAttribute(x,a[x]);(p||svg).appendChild(e);return e}
for(const l of D.landmarks){
  el('circle',{cx:l.x,cy:-l.y,r:l.r,fill:'none',stroke:'var(--lm)','stroke-width':1.2*k,'stroke-dasharray':l.kind==='area'?(4*k)+' '+(3*k):'none',opacity:.8});
  el('circle',{cx:l.x,cy:-l.y,r:2.5*k,fill:'var(--lm)'});
  const t=el('text',{x:l.x+4*k,y:-l.y-4*k,'font-size':11*k,fill:'var(--lm)'});t.textContent=l.name;
}
const pathD=T.map((p,i)=>(i?'L':'M')+p[1]+' '+(-p[2])).join(' ');
el('path',{d:pathD,fill:'none',stroke:'var(--track)','stroke-width':3*k,'stroke-linejoin':'round','stroke-linecap':'round'});
const done=el('path',{d:'',fill:'none',stroke:'var(--done)','stroke-width':3*k,'stroke-linejoin':'round','stroke-linecap':'round'});
const posAt=s=>{let lo=0,hi=T.length-1;while(lo<hi){const m=(lo+hi+1)>>1;if(T[m][0]<=s)lo=m;else hi=m-1}return lo};
let n=0;
for(const d of D.decisions){
  if(d.kind!=='speak'&&d.kind!=='search')continue;
  const p=T[posAt(d.s)];if(!p)continue;
  if(d.kind==='speak'){n++;
    el('circle',{cx:p[1],cy:-p[2],r:7*k,fill:'var(--speak)'});
    const t=el('text',{x:p[1],y:-p[2]+3.5*k,'font-size':9*k,'text-anchor':'middle',fill:'#fff','font-weight':'700'});t.textContent=n;
  }else el('rect',{x:p[1]-3*k,y:-p[2]-3*k,width:6*k,height:6*k,fill:'var(--search)'});
}
const me=el('g',{});
const cone=el('path',{fill:'var(--done)',opacity:.18},me);
el('circle',{r:6*k,fill:'var(--done)',stroke:'var(--card)','stroke-width':2*k},me);
const rows=document.getElementById('rows');
D.decisions.forEach((d,i)=>{
  const tr=document.createElement('tr');tr.className='k-'+d.kind;tr.dataset.s=d.s;
  const c=[fmt(d.s),d.label,d.text?(d.target+'：'+d.text):d.target];
  for(const v of c){const td=document.createElement('td');td.textContent=v;tr.appendChild(td)}
  tr.onclick=()=>show(d.s);rows.appendChild(tr);
});
const range=document.getElementById('t');range.max=T.length?T[T.length-1][0]:0;
function show(s){
  s=Math.max(0,Math.min(+range.max,Math.round(s)));range.value=s;document.getElementById('now').textContent=fmt(s);
  const i=posAt(s),p=T[i];if(!p)return;
  me.setAttribute('transform','translate('+p[1]+' '+(-p[2])+')');
  const a=p[3]*Math.PI/180,L=40*k,w=0.5;
  cone.setAttribute('d','M0 0 L'+(L*Math.sin(a-w))+' '+(-L*Math.cos(a-w))+' L'+(L*Math.sin(a+w))+' '+(-L*Math.cos(a+w))+' Z');
  done.setAttribute('d',T.slice(0,i+1).map((q,j)=>(j?'L':'M')+q[1]+' '+(-q[2])).join(' '));
  let last=null;for(const d of D.decisions){if(d.s>s)break;last=d}
  let sp=null;for(const d of D.decisions){if(d.s>s)break;if(d.kind==='speak')sp=d}
  document.getElementById('say').textContent=(sp?'最後に話したこと（'+fmt(sp.s)+'）：'+sp.text:'まだ話していません')+(last?'　／　最後の判断：'+last.label:'');
  let cur=null;for(const tr of rows.children){tr.classList.remove('cur');if(+tr.dataset.s<=s)cur=tr}
  if(cur)cur.classList.add('cur');
}
let timer=null;const btn=document.getElementById('play');
btn.onclick=()=>{if(timer){clearInterval(timer);timer=null;btn.textContent='再生';return}
  if(+range.value>=+range.max)range.value=0;btn.textContent='止める';
  timer=setInterval(()=>{const v=+range.value+5;show(v);if(v>=+range.max){clearInterval(timer);timer=null;btn.textContent='再生'}},100)};
range.oninput=()=>show(+range.value);
show(0);
</script></body></html>
''';
}

Map<String, String> _reasonText() {
  try {
    final m = jsonDecode(File('assets/reason_codes.json').readAsStringSync());
    final codes = (m as Map)['codes'] as Map;
    return {for (final e in codes.entries) '${e.key}': '${e.value}'};
  } catch (_) {
    return const {};
  }
}
