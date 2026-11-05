import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/ui/glass_overlay.dart';
import 'package:mobile/ui/heading_tape.dart';

void main() {
  test('相対方位は右が正・-180〜180', () {
    expect(relativeBearing(10, 350), 20);
    expect(relativeBearing(350, 10), -20);
    expect(relativeBearing(180, 0), 180);
    expect(relativeBearing(90, 90), 0);
  });

  test('2点間の方位', () {
    expect(bearingBetween(36.70, 137.21, 36.71, 137.21), closeTo(0, 0.01));
    expect(bearingBetween(36.70, 137.21, 36.70, 137.22), closeTo(90, 0.1));
    expect(bearingBetween(36.71, 137.21, 36.70, 137.21), closeTo(180, 0.01));
  });

  testWidgets('視野の中の候補はピン、外の候補は端に出す', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            child: HeadingTape(
              headingDeg: 0,
              candidates: [
                CandidateMark(name: '見本の石碑', bearingDeg: 20, distanceM: 32),
                CandidateMark(name: '見本の橋', bearingDeg: 120, distanceM: 1500),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.text('見本の石碑 32m'), findsOneWidget);
    expect(find.text('見本の橋 1.5km'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });
}
