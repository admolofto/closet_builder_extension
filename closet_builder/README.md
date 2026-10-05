# Closet Builder — SketchUp Extension

Parametric closet system builder. Spawn drawer banks, closets/cabinets (folding
doors with a hanging rod or shelves), L-shaped corner closets, and cubbies with shelves —
then re-edit any unit in place. Every part is a component named after its parents (e.g.
`drawer_bank_1_drawer_1_drawer_face`) with its own material role, ready for
cutlist extensions.

## Install

1. Download `closet_builder.rbz` (or build it — see Development)
2. SketchUp: **Window → Extension Manager → Install Extension** → pick the `.rbz`
3. **Restart SketchUp** (required when upgrading — loaded Ruby is not replaced)
4. Open via **Extensions → Closet Builder → Build Unit...**

## Usage

- Pick a unit type tab (**Drawers / Closet/Cabinet / Corner / Cubby**), set dimensions
  (decimals or fractions like `32 1/2`), options, and materials per part role.
- **Build** places the unit; the dialog switches to editing mode so **Update**
  rebuilds it in place. *"Build a new copy instead"* starts another unit.
- **Re-edit later:** right-click a unit → **Edit Closet Unit...** Parameters are
  stored on the component. Scale-tool resizes are detected and folded back into
  the dimensions on edit; Update rebuilds cleanly at true size.
- **Animate:** the dialog's **Animation** section (Open / Close / Play), or
  right-click one or more units → **Animate Doors and Drawers**. Esc stops.

## Features

**Shared construction**
- Frameless / euro-style, inches; fractions accepted everywhere
- Carcass thickness presets or any custom value; back thickness matches the
  carcass by default (or explicit/custom)
- Full back by default (covers side & top rear edges), or captured inset back
- Top panel rests on the sides (default) or captured between them
- Base: riser with top panel (default), toe kick, or none (corner closets
  always build their own plinth base — see below)
- Riser face: optional decorative board in face/door material, flush with the
  fronts (the riser extends to back it), or set back any depth toe-kick style;
  its own left / right side insets, independent of the face edge gaps
- Face edge gaps: independent left / right / top / bottom — for reveals where
  cabinets sit beside each other or stack
- Per-role materials: carcass, faces/doors, drawer boxes, drawer bottoms,
  backs, shelves

**Drawer banks**
- 1–12 drawers; equal, graduated, or custom heights (`4, 4, *, *, *`,
  top→bottom, `*` shares remaining space)
- Overlay or inset fronts; face reveal and face–carcass stand-off (default 1/4")
- Drawer boxes: own wall thickness (default 1/2") and bottom thickness +
  material (default 1/2"); independent left/right/rear clearances to the
  carcass; bottom box keeps 1" hardware space below, top box 5/8" above
- Optional fixed box depth (blank = interior depth minus rear gap)
- Drawer bottom captured in a groove, extending 3/16" into all four box
  walls by default (toggleable, depth adjustable)

**Closets / cabinets**
- 1 or 2 full-overlay doors, optional bifold leaf split
- Single doors choose a left- or right-hand swing (hinge side recorded
  in the part name: `_lh` / `_rh`); a pair always swings outward
- Door–carcass stand-off gap (default 1/4")
- Interior: hanging rod at any height with optional shelf above, **or**
  1–20 shelves (cabinet), either evenly spaced (equal openings) or a
  centered stack around mid-height at a set clear spacing (default 12")

**Corner closets**
- L-shaped unit wrapping an inside room corner, one continuous interior;
  leg lengths are measured along each wall over the applied finished ends,
  height is the overall envelope including the top caps
- Fixed construction (base/construction toggles don't apply): each leg is a
  complete carcass plus a full-height brace panel along the return wall;
  3/4" applied finished ends on both exposed ends, flush with the door faces;
  top cap panels over each leg out to the door planes
- Plinth base: a four-rail frame under each leg with top panels the
  carcass sits on, set back to the doors' back plane and faced with toe boards flush with the door fronts and
  finished ends
- Optional hanging rod + shelf per leg; one overlay door per leg — the doors
  lap at the corner and the front one (selectable) must open first

**Cubbies**
- Evenly spaced shelves and vertical dividers
- Shelf depth sets the shelves/dividers back from the front edge
  (0 = flush with the carcass, the default)
- Optional 1 or 2 full-overlay doors (single doors choose a hinge side,
  a pair swings outward) with the same door–carcass gap and face edge
  gap controls as closet sections

**Animation**
- Doors swing about their hinge edge, bifold leaves fold flat against each
  other, drawers slide out; a corner closet's front door opens first and
  closes last, and the rear door stops where the open front door blocks it
- Settings (per user, shared by all units): door angle (bifolds stop at
  90°), drawer travel as % of box depth, duration, stagger between parts,
  easing (smooth / soft-close / linear), loop
- **Play** opens, pauses and closes (looping until stopped); **Open** and
  **Close** leave the fronts in that pose as one undoable step
- Works on several selected units at once, including units inside groups
- Units built before animation support need one Update to animate

## Development

```
closet_builder.rb            extension loader
closet_builder/
  main.rb                    menus, context menu, attribute helpers
  builders.rb                all parametric geometry + param normalization
  animation.rb               door / drawer animation (tagged by the builders)
  materials.rb               material presets per part role
  dialog.rb                  HtmlDialog <-> Ruby bridge (scale detection)
  ui/dialog.html             the dialog UI (vanilla JS)
```

Build the installable package from the repo root:

- Windows: `powershell -ExecutionPolicy Bypass -File build.ps1`
- macOS/Linux: `./build.sh`

For fast iteration, copy `closet_builder.rb` + `closet_builder/` into your
SketchUp `Plugins` folder and reload with the Ruby console.

Unit params are stored as JSON in the `AJL_ClosetBuilder` attribute dictionary
on each component instance, so units survive save/reload and copy/paste, and
old units migrate forward when params gain new options.

## License

MIT — see [LICENSE](LICENSE).
