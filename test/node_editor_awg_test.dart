import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/application/dependencies.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/presentation/screens/node_editor_screen.dart';
import 'package:nexus/theme/theme.dart';

/// v0.5.0 §user — the manual-add AmneziaWG 3.1 node lost its parameters:
/// the AWG form block was nested inside the vless/vmess/trojan-only
/// `_isTcpFamily` spread, so a WireGuard selection rendered NO AWG fields
/// and a save produced a plain (param-less) profile; editing a stored AWG
/// node then wiped its params. These tests pin the fixed behavior.
void main() {
  // bootstrapForTest does file I/O — a plain (non-FakeAsync) test zone runs
  // it eagerly; widget tests then consume the ready repository. (Building
  // it inside testWidgets deadlocks: FakeAsync never completes the JsonStore
  // load/write futures.)
  late AppDependencies deps;
  setUpAll(() async {
    deps = await AppDependencies.bootstrapForTest();
  });

  Future<void> pumpEditor(WidgetTester t, {ProxyProfile? existing}) async {
    // A TALL surface: the editor is a lazy ListView and the AWG block sits
    // below the fold on the default 600px test viewport — unbuilt children
    // are invisible to finders. A tall surface builds the whole form.
    await t.binding.setSurfaceSize(const Size(600, 3200));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
      theme: NexusTheme.theme(NexusThemeMode.dark),
      home: NodeEditorScreen(deps: deps, profile: existing),
    ));
    // pumpAndSettle HANGS here (a repeating animated element in the form —
    // likely the focus/caret or scrollbar shimmer), so use bounded pumps.
    await t.pump(const Duration(milliseconds: 100));
  }

  ProxyProfile storedAwgNode() {
    // What a real hand-added AWG 3.1 node looks like after the user typed
    // the amnezia-client values in and saved once.
    return ProxyProfile(
      id: 'awg-stored',
      name: 'AWG node',
      server: '203.0.113.10',
      port: 443,
      protocol: ProxyProtocol.wireguard,
      core: CoreKind.amneziaWg,
      wireguard: WireGuardConfig(
        privateKey: 'STORED_PRIVKEY=',
        peerPublicKey: 'STORED_PEERKEY=',
        endpointHost: '203.0.113.10',
        endpointPort: 443,
        addresses: const ['10.7.0.2/32'],
        mtu: 1280,
        allowedIps: const ['0.0.0.0/0', '::/0'],
      ),
      amnezia: AmneziaParams(
        jc: 4, jmin: 64, jmax: 96, s1: 15, s2: 15, s3: 15, s4: 15,
        h1: '1', h2: '2', h3: '3', h4: '4',
        masqId: 'www.google.com',
        extra: const {'custom': 'kept'},
      ),
    );
  }

  testWidgets('manual ADD: the full AWG 3.1 form renders for WireGuard',
      (t) async {
    await pumpEditor(t);
    // Select the WireGuard / AmneziaWG chip (last protocol chip).
    await t.tap(find.text('WireGuard / AmneziaWG'));
    await t.pump(const Duration(milliseconds: 100));

    expect(find.text('AMNEZIAWG 3.1 PARAMS'), findsOneWidget,
        reason: 'the AWG section MUST render for WireGuard '
            '(was swallowed by the _isTcpFamily nesting)');
    for (final f in ['Jc', 'Jmin', 'Jmax', 'S1', 'S2', 'S3', 'S4',
      'H1 (n / N-M)', 'I1 — decoy packet DSL, e.g. <b 0x1603030001><t>',
      'Hpk — header protection key (3.x)']) {
      expect(find.text(f), findsWidgets, reason: 'field $f must be visible');
    }
    expect(find.text('AWG 3.1 defaults (anti-DPI)'), findsOneWidget);
    expect(find.text('RandomTrailers'), findsOneWidget);
    expect(find.text('DisableCookies'), findsOneWidget);
  });

  testWidgets('manual ADD: filling AWG fields stores a full AmneziaParams',
      (t) async {
    await pumpEditor(t);
    await t.tap(find.text('WireGuard / AmneziaWG'));
    await t.pump(const Duration(milliseconds: 100));

    Future<void> type(String label, String value) async {
      await t.enterText(find.widgetWithText(TextField, label).last, value);
      await t.pump();
    }

    await t.enterText(find.widgetWithText(TextField, 'Name').first, 'awg-man');
    await type('Server / address', '203.0.113.9');
    await type('Port', '51820');
    await type('Private key', 'PRIV=');
    await type('Peer public key', 'PEER=');
    await type('Jc', '4');
    await type('Jmin', '50');
    await type('Jmax', '100');
    await type('S1', '15');
    await type('S2', '15');
    await type('H1 (n / N-M)', '1234');
    await type('H2 (n / N-M)', '1235');

    await t.tap(find.text('Save node'));
    // Run out the repository's debounced 400ms flush timer — the test
    // binding fails on still-pending timers at teardown.
    await t.pump(const Duration(milliseconds: 500));

    final saved = deps.profiles.all.firstWhere((p) => p.name == 'awg-man');
    // The debounced flush (400ms) never fires in FakeAsync — the in-memory
    // repository state IS the truth here.
    expect(saved.amnezia, isNotNull,
        reason: 'the AWG bundle must survive the save path');
    expect(saved.amnezia!.jc, 4);
    expect(saved.amnezia!.jmin, 50);
    expect(saved.amnezia!.jmax, 100);
    expect(saved.amnezia!.s1, 15);
    expect(saved.amnezia!.h1, '1234');
    expect(saved.core, CoreKind.amneziaWg,
        reason: 'AWG params ⇒ AmneziaWG core, not plain wireguard');
  });

  testWidgets('EDIT: re-saving a stored AWG node does not wipe its params',
      (t) async {
    final stored = storedAwgNode();
    await deps.profiles.upsertMany([stored]);
    await pumpEditor(t, existing: stored);

    // The form must be SEEDED with the stored values…
    expect(find.text('AMNEZIAWG 3.1 PARAMS'), findsOneWidget);
    final jc = t.widget<TextField>(
        find.ancestor(of: find.text('Jc').first, matching: find.byType(TextField)));
    expect(jc.controller!.text, '4');

    // …and a plain name edit + save keeps the whole obfuscation set.
    await t.enterText(find.widgetWithText(TextField, 'Name').first,
        'AWG node renamed');
    await t.tap(find.text('Save node'));
    // The in-memory repository is updated synchronously; run out the
    // debounced flush timer so the test binding sees no pending timers.
    await t.pump(const Duration(milliseconds: 500));

    final saved = deps.profiles.byId('awg-stored')!;
    expect(saved.amnezia!.jc, 4);
    expect(saved.amnezia!.jmin, 64);
    expect(saved.amnezia!.s3, 15);
    expect(saved.amnezia!.h1, '1');
    // Form-not-exposed fields ride along untouched.
    expect(saved.amnezia!.masqId, 'www.google.com');
    expect(saved.amnezia!.extra['custom'], 'kept');
  });

  testWidgets('EDIT: clearing a field clears the stored param (explicit)',
      (t) async {
    final stored = storedAwgNode();
    await deps.profiles.upsertMany([stored]);
    await pumpEditor(t, existing: stored);

    await t.enterText(
        find.widgetWithText(TextField, 'Jc').first, ''); // explicit clear
    await t.tap(find.text('Save node'));
    await t.pump(const Duration(milliseconds: 500)); // flush timer

    final saved = deps.profiles.byId('awg-stored')!;
    expect(saved.amnezia!.jc, isNull,
        reason: 'the form is the source of truth — an emptied field clears');
    expect(saved.amnezia!.jmin, 64, reason: 'untouched fields persist');
  });
}
