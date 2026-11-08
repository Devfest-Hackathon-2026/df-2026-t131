import 'dart:js_interop';

@JS('open') // globalThis.open（＝window.open）
external JSAny? _windowOpen(JSString url, JSString target, JSString features);

/// 新しいタブで開く（開いたページから判断画面を操作されないよう noopener）。
void openUrl(String url) {
  _windowOpen(url.toJS, '_blank'.toJS, 'noopener'.toJS);
}
