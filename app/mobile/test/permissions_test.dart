import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/main.dart';
import 'package:mobile/startup/permissions.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  test('マイクの権限を求める（「検索して」の聞き取り用）', () {
    final perms = requiredPermissions.map((p) => p.permission);
    expect(perms, contains(Permission.microphone));
  });

  test('拒否された権限だけを順番どおりに返す', () async {
    final asked = <Permission>[];
    final denied = await requestAll(
      requester: (p) async {
        asked.add(p);
        return p != Permission.camera;
      },
    );
    expect(asked, requiredPermissions.map((p) => p.permission).toList());
    expect(denied.map((p) => p.permission), [Permission.camera]);
  });

  testWidgets('すべて許可されたら準備完了を出す', (tester) async {
    await tester.pumpWidget(
      MobileApp(
        requestPermissions: () async => [],
        readyBuilder: (_) => const Text('準備ができました'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('準備ができました'), findsOneWidget);
  });

  testWidgets('拒否されたら理由を出して止まる', (tester) async {
    await tester.pumpWidget(
      MobileApp(requestPermissions: () async => [requiredPermissions[1]]),
    );
    await tester.pumpAndSettle();
    expect(find.text('次の権限が必要です'), findsOneWidget);
    expect(find.textContaining('カメラ'), findsOneWidget);
  });
}
