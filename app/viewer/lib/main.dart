import 'package:flutter/material.dart';

import 'src/viewer_page.dart';

void main() {
  runApp(const ViewerApp());
}

/// 判断画面の Web 版（審査用のデプロイURLで歩行ログを再生する）。
class ViewerApp extends StatelessWidget {
  const ViewerApp({super.key, this.showMapTiles = true});

  /// 地図のタイル（地理院タイル）を読むか。テストでは false。
  final bool showMapTiles;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '判断画面｜まちトーク',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: ViewerPage(showMapTiles: showMapTiles),
    );
  }
}
