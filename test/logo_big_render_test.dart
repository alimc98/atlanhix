import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/presentation/widgets/atlanhix_logo.dart';

void main() {
  testWidgets('big logo render for eyeballing', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              AtlanhixMark(size: 160, strokeColor: Colors.black),
              SizedBox(height: 40),
              AtlanhixLogo(height: 90, strokeColor: Colors.black),
            ],
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    await expectLater(find.byType(Scaffold),
        matchesGoldenFile('goldens/logo_big.png'));
  });
}
