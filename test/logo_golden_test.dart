import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/presentation/widgets/atlanhix_logo.dart';

void main() {
  testWidgets('line-type wordmark + mark render as pure strokes', (t) async {
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
              AtlanhixMark(size: 64, strokeColor: Colors.black),
              SizedBox(height: 16),
              AtlanhixLogo(height: 36, strokeColor: Colors.black),
              SizedBox(height: 12),
              AtlanhixLogo(height: 18, strokeColor: Colors.black),
            ],
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    await expectLater(
        find.byType(Scaffold), matchesGoldenFile('goldens/logo_light.png'));
  });
}
