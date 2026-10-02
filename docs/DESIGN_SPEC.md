# LumaFrame — Design Spec

One shared visual spec, implemented twice (`App/Sources/DesignSystem/Theme.swift` and
`android/.../design/Theme.kt`). If a value is not in this file, do not invent one.

Dark, low-chrome, studio-neutral. It must disappear in front of a photograph. Own
visual identity — no third-party brand elements, logos, or recognisable proprietary
iconography. All glyphs are drawn from SF Symbols / Material Symbols equivalents of
the same generic shape.

## Color

| Token | Value | Use |
| --- | --- | --- |
| `surface.base` | `#0B0B0C` | Screen background, behind the viewfinder |
| `surface.raised` | `#17181A` | Panels, sheets, cards |
| `surface.scrim` | `#000000` @ 60% | Behind modal sheets only |
| `stroke.subtle` | `#2A2C30` | Hairline dividers, grid lines |
| `stroke.strong` | `#4A4D53` | Active control outlines |
| `text.primary` | `#F2F3F5` | Values, titles |
| `text.secondary` | `#9BA0A8` | Labels, units |
| `text.disabled` | `#5C6068` | Controls that exist but are unavailable |
| `accent.active` | `#F2C14E` | Active mode, shutter ring, focus reticle, recording dot |
| `accent.compare` | `#6FA8FF` | Before/after compare state, focus peaking |
| `state.warn` | `#E8804A` | Unsupported setting, thermal warning |
| `state.error` | `#E2564C` | Capture error |
| `state.lock` | `#8F7BD8` | AE / AF / AWB lock badges |

Rules:

- The viewfinder is the only bright thing on screen. Chrome sits at `text.secondary`
  or below except for the value the user is currently changing.
- The accent is used for **state**, never for decoration. No gradients, no glows.
- Overlays drawn on top of the preview use `text.primary` and `stroke.strong` at
  minimum, so they stay readable over both a blown window and a black frame.

## Spacing

4pt / 4dp base grid. Only these values:

`2, 4, 8, 12, 16, 24, 32, 48`

| Context | Value |
| --- | --- |
| Screen edge padding | 16 |
| Between related controls | 8 |
| Between control groups | 16 |
| Bottom stack to screen edge | 24 |
| Minimum touch target | **44pt / 48dp** |

## Radius

| Token | Value |
| --- | --- |
| `radius.control` | 10 |
| `radius.panel` | 16 |
| `radius.pill` | 999 (fully rounded) |
| `radius.viewfinder` | 0 |

## Typography

System font only. Sizes are fixed; Dynamic Type still scales them.

| Token | Size / line height | Weight | Use |
| --- | --- | --- | --- |
| `type.value` | 17 / 22 | semibold | Live ISO, shutter, Kelvin |
| `type.title` | 17 / 22 | regular | Section titles |
| `type.label` | 13 / 16 | medium, tracking +0.4 | Control labels, units |
| `type.caption` | 11 / 14 | medium, tracking +0.6 | Badges, debug overlay |
| `type.mono` | 13 / 18 | monospaced | EXIF, diagnostics, log |

Rules: the live parameter value is always `type.value`; the label above it is
`type.label`. Units are `type.label` in `text.secondary`, never inside the value
string, so the number does not reflow as it changes.

## Motion

| Token | Duration | Curve |
| --- | --- | --- |
| `motion.tap` | 120ms | ease-out |
| `motion.control` | 180ms | ease-in-out |
| `motion.mode` | 240ms | spring, low damping |
| `motion.overlay` | 90ms | linear (overlays must not feel laggy) |

Rules:

- Overlays (grid, level, histogram, peaking, zebra) update on a **10–15 fps Canvas**
  and never trigger a full-screen recomposition.
- **Mode switching must not restart the camera session.** Only the visible chrome
  crossfades. The viewfinder never jumps, resizes, or flashes.
- The shutter responds immediately. If processing is still running, show a
  "processing" indicator — never block the button.
- Respect Reduce Motion / `Settings.Global.ANIMATOR_DURATION_SCALE = 0` by collapsing
  durations to 0 and skipping the mode spring.

## Layout

```text
+----------------------------------+
| status row   flash timer badges  |  <- status only, never controls
|                                  |
|                                  |
|           VIEWFINDER             |  <- fills the screen, 4:3 / 3:4 / 16:9 letterboxed
|                                  |
|      [ overlays: grid, level,    |
|        histogram, peaking, zebra ]
+----------------------------------+
| contextual controls (mode-aware) |
| mode switcher  Auto | Pro | Looks|
|  [gallery]     ( O )     [flip]  |
+----------------------------------+
```

- Top row is **status only**. No tappable controls, so nothing is ever under the
  user's finger at the top while composing.
- The bottom stack is the only interactive region: contextual controls, then mode
  switcher, then shutter with gallery thumbnail and camera flip.
- The viewfinder keeps its aspect ratio through rotation; only the surrounding
  controls rotate. The shutter stays bottom-centre in both orientations.
- Landscape moves the control stack to the trailing edge as a single column; the
  viewfinder does not re-letterbox.

## Controls

- **Pro dial**: one parameter at a time, ruler-style, continuous drag with detents
  at the device's real min/max (never a synthetic range). Live value in `type.value`.
  An `AUTO` chip per parameter; tapping it returns that parameter to auto without
  touching the others.
- **Style carousel**: horizontal, live thumbnails, selected item scaled 1.0 and
  unselected 0.85, strength slider below.
- **Long-press any style or the viewfinder** → compare with the original. The
  compare state is `accent.compare`, and it is a hold, not a toggle.
- **Tap to focus** shows a reticle in `accent.active` plus a vertical exposure
  slider. Pinch zooms. Both operate on the capability set, so a single-lens device
  has no zoom steps and no zoom control at all.

## Accessibility

- Every control has a label and a value spoken together (`"ISO 400"`, not `"ISO"`).
- Hidden means `accessibilityHidden` too, not just visually absent.
- Controls rotate and reflow with larger text instead of truncating.
- Haptics: `selection` on dial detents and mode change, `impact(light)` on shutter,
  `impact(rigid)` on focus lock. Respect the system haptics setting.

## Debug overlay

Toggleable, off by default, `type.mono` at 60% opacity in `text.secondary`:

```text
30.2 fps | ML gpu 4.1 ms | ISO 400 1/120 EV 0.0 | plain | 412 MB
```

One line, `surface.raised` at 50% behind it, top-left under the status row. It is
part of the same overlay Canvas as the grid so it costs one draw, not two.
