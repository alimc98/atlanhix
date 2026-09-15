import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/presentation/widgets/atlanhix_logo.dart';

void main() {
  testWidgets('line-type weave wordmark renders', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: ThemeData(
        brightness: Brightness.light,
        textTheme: const TextTheme(titleMedium: TextStyle(color: Colors.black)),
      ),
      home: Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              AtlanhixLogo(height: 36, lineColor: Color(0xFF4F8CFF)),
              SizedBox(height: 12),
              AtlanhixLogo(
                  height: 18, lineColor: Color(0xFF4F8CFF), overlap: 0.5),
            ],
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    await expectLater(find.byType(Scaffold),
        matchesGoldenFile('goldens/logo_light.png'));
  });
}
