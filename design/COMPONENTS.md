# NEXUS Components

Authoritative specs; implementations live in `lib/presentation/widgets/` and
must match these rules. Measurements are logical pixels.

## StatusDot
8×8 circle. Healthy: `success` + 6 px glow (20% alpha). Checking: `info`,
pulsing opacity 1→0.4 @ 1 s loop. Degraded: `warning`. Error states: `error`.
Never color-only — pairs with text label in lists ("● Healthy").

## MetricTile
Label (`overline`, textMuted) over value (`metric`). Value uses tabular mono.
Used for latency, speeds, session time, node counts. Min width 72; on narrow
layouts wraps into 2-col grid instead of shrinking type.

## ConnectButton
56 px circle, 64 px hit area. States:
`idle` (accent fill, power glyph) → `connecting` (indeterminate ring, disabled)
→ `connected` (success fill, check glyph, subtle 2 px breathing glow, 2 s
period) → `disconnecting` (ring reversal) → `error` (error fill, exclamation,
tap = diagnostics). State changes animate 250 ms easeOutCubic morph.

## NodeTile
Row 72 px: flag/region glyph (28), name (bodyStrong) + chips row (caption,
accentSoft bg: protocol, core, security), trailing: latency (`metric`,
success/warn/error colored) + StatusDot. Selected (active node): 2 px accent
left-edge bar + surfaceElevated. Tap → detail; trailing chevron desktop /
long-press quick menu mobile. `RepaintBoundary` per tile.

## SectionCard
Surface radius 16, padding 16/20, optional header row (headline + trailing
action). Groups dashboard metrics, subscription summary, chain editor blocks.

## SpeedGraph
CustomPainter area chart, 96 px tall. Down (info) + Up (success) series,
60 fps, samples ring buffer 120 points, grid at 25/50/75%, no per-frame
shadows. Empty state: dashed baseline + "waiting for traffic".

## EmptyState / ErrorState
Centered: 48 px glyph (outline), title (headline), body (body, textSecondary),
optional action button. ErrorState adds "Details" expander with raw error +
"Copy diagnostics".

## ChainBlock / ChainConnector
ChainBlock: 88 px min-height card with icon, title, subtitle (engine), drag
handle. ChainConnector: 24 px vertical line with animated arrow on reorder.
Drop targets highlight with accentSoft border.

## LogLine
Mono 12/16, level glyph colored, timestamp muted, message selectable, secrets
redacted upstream (logger layer). Virtualized; 10k lines cap in memory.

## Dialogs & sheets
Desktop: modal dialog radius 16, width 480 max. Mobile: bottom sheet radius
24 top corners, drag handle. Destructive actions: error-tinted button,
require explicit confirmation text for irreversible deletes.
