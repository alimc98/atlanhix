import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/presentation/widgets/atlanhix_logo.dart';

void main() {
  testWidgets('weave monogram renders on light and dark', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(24),
              child: const AtlanhixLogo(
                  height: 90, lineColor: Color(0xFF4F8CFF)),
            ),
            Container(
              color: const Color(0xFF0A0B0E),
              padding: const EdgeInsets.all(24),
              child: const AtlanhixLogo(
                  height: 90,
                  inkColor: Color(0xFFE8E9ED),
                  lineColor: Color(0xFF4F8CFF),
                  overlap: 0.5),
            ),
          ],
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.byType(AtlanhixLogo), findsNWidgets(2));
    await expectLater(
        find.byType(Scaffold), matchesGoldenFile('goldens/logo_weave.png'));
  });
}
