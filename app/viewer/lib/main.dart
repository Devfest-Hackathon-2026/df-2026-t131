import 'package:flutter/material.dart';

import 'src/viewer_page.dart';

void main() {
  runApp(const ViewerApp());
}

/// 判断画面の Web 版（審査用のデプロイURLで歩行ログを再生する）。
class ViewerApp extends StatelessWidget {
  const ViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '判断画面｜アンビエント・ナラティブガイド',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const ViewerPage(),
    );
  }
}
