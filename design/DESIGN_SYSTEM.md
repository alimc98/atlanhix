# NEXUS Design System

NEXUS has an original visual identity: a *precision instrument* aesthetic —
dark-first, calm surfaces, one accent hue doing all the emotional work, data
rendered like a modern observability tool (think Linear × Raycast × flight
instruments), not a Windows-95 proxy panel.

## Principles

1. **5-second comprehension** — the dashboard answers: connected? which node?
   healthy? how fast? what core? (§81 of product spec)
2. **One accent, many neutrals** — the entire palette is neutral; color is
   reserved for state (healthy/degraded/error) and the single brand accent.
3. **Depth by elevation, not borders** — subtle surface tints + shadows;
   hairlines only where tables/dividers demand them.
4. **Motion is information** — animations confirm state transitions
   (connect pulse, health-dot color morph, speed-graph scroll); no decorative
   bouncing. All transitions 150–300 ms, `Curves.easeOutCubic` family.
5. **Dense where experts live, calm where humans land** — dashboards breathe;
   node lists are information-dense but zebra-free, with whitespace rhythm.

## Tokens (semantic, never raw colors in widgets)

```
background · surface · surfaceElevated · surfaceSunken
textPrimary · textSecondary · textMuted · textOnAccent
accent · accentSoft · success · warning · error · info
border · borderStrong · overlayScrim
```

* Dark: `#0B0F14` bg, `#111820` surface, `#1A2430` elevated, accent `#4F8CFF`.
* OLED: true black `#000000`, surfaces `#0A0A0C`/`#121216`, same accent.
* Light: `#F6F8FA` bg, `#FFFFFF` surface, `#0B1220`-based text, accent `#2563EB`.

Full scales in `COLORS.md`.

## Typography

* Latin: **Inter** (UI) — geometric-humanist, excellent at small sizes.
* Persian: **Vazirmatn** — pairs with Inter in rhythm and weight; RTL-first.
* Mono: **JetBrains Mono** for latency numbers, IPs, JSON, logs.
* Scale (1.25 ratio): display 32/40, title 20/28, headline 16/24,
  body 14/20, caption 12/16, mono-tabular for all metrics.

## Spacing & shape

* 4-pt grid; paddings 4/8/12/16/24/32; card padding 16 (mobile) / 20 (desktop).
* Radius: cards 16, sheets 24, chips 8, inputs 12, status dots 999.
* Elevation: E1 shadow `0 1 2 rgba(0,0,0,.24)`, E2 `0 4 16 rgba(0,0,0,.28)`
  (dark), lighter in light theme. Hairline `border` on top edges only.

## Components

* `StatusDot` — 8 px health dot with soft glow when healthy, pulse on checking.
* `MetricTile` — label-over-value with mono numerals.
* `ConnectButton` — 56 px, accent fill; idle ring → progress ring → connected
  checkmark morph.
* `NodeTile` — flag · name · protocol chips · latency · health; tap =
  detail; trailing = connect.
* `SectionCard`, `EmptyState`, `ErrorBanner`, `LogLine`, `SpeedGraph`.

Interaction & accessibility rules: see `UX_RULES.md`; component specs in
`COMPONENTS.md`.
