# NEXUS Color System

All colors are defined once in `lib/theme/palette.dart` and consumed only via
semantic tokens. Raw hex values in widgets = review failure.

## Dark (default)

| Token | Value | Usage |
|---|---|---|
| `background` | `#0B0F14` | app background |
| `surface` | `#111820` | cards, lists |
| `surfaceElevated` | `#1A2430` | dialogs, sheets, hover |
| `surfaceSunken` | `#080C10` | wells, code blocks |
| `textPrimary` | `#E8EEF5` | primary text |
| `textSecondary` | `#9AA7B4` | labels |
| `textMuted` | `#5C6B7A` | hints, disabled |
| `accent` | `#4F8CFF` | primary actions, connect |
| `accentSoft` | `#4F8CFF @ 14%` | chip backgrounds |
| `success` | `#34D399` | healthy, connected |
| `warning` | `#FBBF24` | degraded, expiry soon |
| `error` | `#F87171` | offline, errors |
| `info` | `#38BDF8` | checking, informational |
| `border` | `#FFFFFF @ 7%` | hairlines |
| `borderStrong` | `#FFFFFF @ 14%` | dividers, focused inputs |
| `overlayScrim` | `#000000 @ 55%` | modal scrims |

## OLED

True-black variant: `background #000000`, `surface #0A0A0C`,
`surfaceElevated #131318`, `surfaceSunken #000000`; accent unchanged; shadows
replaced with 1px borders (no glow on OLED).

## Light

| Token | Value |
|---|---|
| `background` | `#F6F8FA` |
| `surface` | `#FFFFFF` |
| `surfaceElevated` | `#FFFFFF` (shadow E2) |
| `surfaceSunken` | `#EEF2F6` |
| `textPrimary` | `#0B1220` |
| `textSecondary` | `#47536B` |
| `textMuted` | `#8A94A6` |
| `accent` | `#2563EB` |
| `success` | `#059669` |
| `warning` | `#B45309` |
| `error` | `#DC2626` |
| `info` | `#0284C7` |
| `border` | `#0B1220 @ 8%` |
| `borderStrong` | `#0B1220 @ 16%` |

## Health colors (shared)

`healthy` success · `degraded` warning · `checking` info · `timeout` warning ·
`offline` textMuted · `blocked` error · `coreError`/`configError` error ·
`unknown` textMuted.

## Data-vis (speed graph)

Down: `#38BDF8` fill @ 22%, line solid · Up: `#34D399` fill @ 18%, line solid ·
grid: `border` · 60 fps-friendly (CustomPainter, no shadows per frame).
