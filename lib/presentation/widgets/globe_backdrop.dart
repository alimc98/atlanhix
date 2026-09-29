import 'package:flutter/material.dart';

import '../../core/net/geo_locator.dart';
import '../../domain/entities/proxy_profile.dart';
import '../../theme/theme.dart';
import '../globe/atlanhix_globe_view.dart';
import '../globe/globe_geo.dart';
import 'dashboard_globe.dart' show GlobeAnchor, GlobeAnchorKind;

/// v0.5.2 §user — THE GLOBE IS THE APP BACKGROUND. v0.5.4 §globe3d: the
/// backdrop now renders the SIGNATURE 3D planet ([AtlanhixGlobeView]) —
/// GPU shader surface, real great-circle route user→node with packet flow,
/// slow cinematic rotation — instead of the flat point cloud.
///
/// The widget keeps its v0.5.2 public API ([connected], [connecting],
/// [anchors]) so the shell and the existing tests are untouched; inside,
/// the anchors are converted to globe locations and the connection state
/// maps onto the visual state machine 1:1 (no fake VPN state).
class GlobeBackdrop extends StatelessWidget {
  const GlobeBackdrop({
    super.key,
    required this.connected,
    required this.connecting,
    this.anchors = const [],
    this.disconnecting = false,
    this.error = false,
    this.source,
    this.destination,
  });

  final bool connected;
  final bool connecting;

  /// Legacy anchor list (home/exit pins from the geo layer). When
  /// [destination] is not supplied explicitly the EXIT anchor becomes it.
  final List<GlobeAnchor> anchors;

  final bool disconnecting;
  final bool error;

  /// Explicit source (user origin). Falls back to the HOME anchor, then
  /// null (calm un-anchored globe — never a fake location).
  final GlobeLocation? source;

  /// Explicit destination (selected node). Falls back to the EXIT anchor.
  final GlobeLocation? destination;

  GlobeVisualState get _visualState {
    if (error) return GlobeVisualState.error;
    if (connected) return GlobeVisualState.connected;
    if (connecting) return GlobeVisualState.connecting;
    if (disconnecting) return GlobeVisualState.disconnecting;
    return GlobeVisualState.idle;
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    // Anchors → locations (home = first, exit = last, the painter's
    // contract from the point-cloud globe).
    GlobeLocation? src = source;
    GlobeLocation? dst = destination;
    if (src == null) {
      final home = anchors
          .where((a) => a.kind == GlobeAnchorKind.home)
          .toList();
      if (home.isNotEmpty) {
        src = GlobeLocation(
            lat: home.first.lat, lon: home.first.lon, label: '');
      }
    }
    if (dst == null) {
      final exits =
          anchors.where((a) => a.kind == GlobeAnchorKind.exit).toList();
      if (exits.isNotEmpty) {
        dst = GlobeLocation(
            lat: exits.last.lat, lon: exits.last.lon, label: '');
      }
    }

    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: Theme.of(context).scaffoldBackgroundColor),
          // The 3D planet: lower half (reference composition), tinted by
          // state through the view's own atmosphere/rim machine.
          Positioned(
            left: -80,
            right: -80,
            bottom: -120,
            height: MediaQuery.sizeOf(context).height * 0.85,
            child: Opacity(
              opacity: 0.5,
              child: AtlanhixGlobeView(
                source: src,
                destination: dst,
                state: _visualState,
              ),
            ),
          ),
          // Connection wash: the green breath on connect (kept from the
          // v0.5.2 backdrop — the app visibly changes mood).
          if (connected || connecting)
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, 0.55),
                  radius: 1.1,
                  colors: [
                    c.success.withValues(alpha: connected ? 0.10 : 0.05),
                    Theme.of(context)
                        .scaffoldBackgroundColor
                        .withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          // Readability vignette: the top half stays near-solid background
          // so lists/cards render over it cleanly.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.center,
                colors: [
                  Theme.of(context)
                      .scaffoldBackgroundColor
                      .withValues(alpha: 0.86),
                  Theme.of(context)
                      .scaffoldBackgroundColor
                      .withValues(alpha: 0.0),
                ],
                stops: const [0.0, 1.0],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// v0.5.4 §globe3d — NODE → GEOLOCATION resolver for the dashboard: turns
/// the selected [ProxyProfile] into a globe destination using (in order):
///  1. the live geo layer (host fix already resolved for this node),
///  2. the country-code hints the node name/host already carry
///     ("DE-01", flag emoji, TLD) → country centroid,
///  3. nothing — the globe stays calm instead of inventing a pin.
GlobeLocation? destinationForNode(ProxyProfile? node, GeoLocator? geo) {
  if (node == null) return null;
  final host = geo?.lastHost;
  if (host != null) {
    return GlobeLocation(
      lat: host.lat,
      lon: host.lon,
      label: host.hasCity ? host.city : host.countryName,
      city: host.city,
      countryCode: host.countryCode,
      exact: true,
    );
  }
  final cc = guessCountryCode(node.name, node.server);
  if (cc.isEmpty) return null;
  final fallback = kCountryCentroids[cc];
  if (fallback == null) return null;
  return GlobeLocation(
    lat: fallback.lat,
    lon: fallback.lon,
    label: fallback.label,
    countryCode: cc,
    exact: false,
  );
}
