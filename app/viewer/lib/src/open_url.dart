// リンクを新しいタブで開く。Web では window.open、テスト（VM）では何もしない。
// ライブラリを足さないため（足すと著作物利用シートにも載せる必要がある）、条件付き import で分ける。
export 'open_url_stub.dart' if (dart.library.js_interop) 'open_url_web.dart';
