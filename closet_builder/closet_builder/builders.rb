# Closet Builder - parametric geometry.
#
# Coordinate system (component-local, inches):
#   X = width (left -> right)
#   Y = depth (front face at y = 0, back at y = depth; overlay fronts overhang to -y)
#   Z = height (floor at z = 0)
#
# Frameless / euro-style construction. Fronts are full-overlay or inset.
#
# Base types:
#   none     - carcass sits on the floor
#   toe_kick - sides run to the floor, bottom raised, recessed kick board
#   riser    - separate plinth box; whole carcass (incl. sides) sits on top of
#              it; optional decorative face flush with the fronts (or set back
#              toe-kick style)
#   (corner closets ignore the base/construction toggles - they always get a
#   plinth rail frame with flush toe boards, finished ends and top caps)
#
# Top construction:
#   top_on_sides (default) - top panel rests ON the side panels (full width/depth)
#   otherwise              - top captured between the sides

require 'json'

module AJL
  module ClosetBuilder
    module Builders
      # ------------------------------------------------------------------
      # Entry point. Builds a new unit, or rebuilds +instance+ in place.
      # ------------------------------------------------------------------
      def self.build(params, instance = nil)
        model = Sketchup.active_model
        params = normalize(params)
        model.start_operation('Closet Builder', true)

        if instance && instance.valid?
          definition = instance.definition
          # Legacy units ("CB Drawer Bank" era) get renamed into the
          # {type}_{n} scheme so part names can be prefixed with it.
          unless definition.name =~ /\A#{Regexp.escape(params['type'])}_\d+\z/
            definition.name = unit_name(model, params['type'])
          end
          purge_parts(definition)
          # Drop any Scale-tool scaling: geometry is rebuilt at true size,
          # keeping the unit's position and rotation.
          tr = instance.transformation
          instance.transformation = Geom::Transformation.axes(
            tr.origin, tr.xaxis.normalize, tr.yaxis.normalize, tr.zaxis.normalize
          )
        else
          definition = model.definitions.add(unit_name(model, params['type']))
          tr = Geom::Transformation.new(next_placement(model))
          instance = model.active_entities.add_instance(definition, tr)
        end

        mats = Materials.role_materials(model, params)
        u = definition.name
        case params['type']
        when 'drawer_bank' then drawer_bank(definition.entities, params, mats, u)
        when 'closet'      then closet_section(definition.entities, params, mats, u)
        when 'corner_closet' then corner_closet(definition.entities, params, mats, u)
        when 'cubby'       then cubby(definition.entities, params, mats, u)
        else
          model.abort_operation
          raise ArgumentError, "Unknown unit type: #{params['type']}"
        end

        instance.set_attribute(DICT, 'params', params.to_json)
        instance.set_attribute(DICT, 'type', params['type'])
        model.commit_operation
        instance
      rescue StandardError => e
        model.abort_operation rescue nil
        UI.messagebox("Closet Builder error: #{e.message}")
        raise
      end

      # ------------------------------------------------------------------
      # Unit builders
      # ------------------------------------------------------------------

      def self.drawer_bank(ents, p, m, u)
        w, h, d, t = dims(p)
        bi = base_info(p)
        carcass(ents, p, m, u)

        n      = p['drawer_count']
        rv     = p['reveal']
        inset  = p['front_style'] == 'inset'
        ib     = bi[:bottom_z] + t          # interior bottom (top of bottom panel)
        it     = h - t                      # interior top (underside of top panel)
        iw     = w - 2 * t                  # interior width
        id_    = d - p['back_thickness']    # interior depth

        if inset
          # Faces live inside the opening, flush with the carcass front edge.
          x0    = t + rv
          fw    = iw - 2 * rv
          z     = ib + rv
          avail = (it - rv) - z - (n - 1) * rv
          fy    = 0.0
        else
          # Full overlay: faces cover the carcass front; each edge gap is
          # independent so stacked / side-by-side cabinets can share reveals.
          x0    = p['face_left_gap']
          fw    = w - p['face_left_gap'] - p['face_right_gap']
          z     = bi[:bottom_z] + p['face_bottom_gap']
          avail = (h - p['face_top_gap']) - z - (n - 1) * rv
          fy    = -(t + p['face_gap']) # stand-off between face back and carcass front
        end
        raise "Unit too small for #{n} drawers" if avail < n * 1.0

        heights = resolve_heights(avail, n, p)

        n.times do |i|
          fh = heights[i]
          dn = "#{u}_drawer_#{i + 1}"
          drawer = ents.add_group
          de = drawer.entities

          panel(de, "#{dn}_drawer_face", [x0, fy, z], [fw, t, fh], m[:face])

          # Drawer box. Clearances to the carcass are configurable:
          #   box_left_gap / box_right_gap - per side (slides)
          #   box_rear_gap   - to the back panel
          #   box_bottom_gap - lowest box above the carcass bottom
          #   box_top_gap    - top box below the carcass top
          bw = iw - p['box_left_gap'] - p['box_right_gap']
          # Box depth: explicit override if set, else fill the interior
          # less the rear gap.
          bd = p['box_depth'] > 0 ? [p['box_depth'], id_].min : id_ - p['box_rear_gap']
          bx = t + p['box_left_gap']
          # Box height is independent of the face for the bottom and top
          # drawers: the bottom box sits box_bottom_gap above the carcass
          # bottom (undermount hardware space), the top box stops
          # box_top_gap below the carcass top.
          face_top = z + fh
          bz       = i.zero?     ? ib + p['box_bottom_gap'] : z + 0.75
          box_top  = i == n - 1  ? it - p['box_top_gap']    : [face_top, it].min - 0.75
          bz = [bz, ib].max
          bh = [box_top - bz, 1.0].max

          bo  = p['box_thickness']    # box wall material
          bot = p['bottom_thickness']  # drawer bottom material
          # Captured bottom: the panel extends `gi` into each wall, as if
          # sitting in a groove/rabbet cut into the four box sides.
          gi  = p['bottom_groove'] ? [p['bottom_groove_depth'], bo].min : 0.0
          box = de.add_group
          be = box.entities
          bn = "#{dn}_drawer_box"
          panel(be, "#{bn}_left",   [bx, 0, bz],             [bo, bd, bh],            m[:box])
          panel(be, "#{bn}_right",  [bx + bw - bo, 0, bz],   [bo, bd, bh],            m[:box])
          panel(be, "#{bn}_front",  [bx + bo, 0, bz],        [bw - 2 * bo, bo, bh],   m[:box])
          panel(be, "#{bn}_back",   [bx + bo, bd - bo, bz],  [bw - 2 * bo, bo, bh],   m[:box])
          panel(be, "#{bn}_bottom", [bx + bo - gi, bo - gi, bz + bo],
                [bw - 2 * (bo - gi), bd - 2 * (bo - gi), bot], m[:bottom])
          componentize(box, bn)
          # Slides straight out, up to the box depth; the top drawer
          # opens first.
          tag_motion(componentize(drawer, dn),
                     'kind' => 'slide', 'travel' => bd, 'seq' => n - 1 - i)

          z += fh + rv
        end
      end

      def self.closet_section(ents, p, m, u)
        w, h, d, t = dims(p)
        bt = p['back_thickness']
        carcass(ents, p, m, u)

        if p['closet_interior'] == 'shelves'
          # Cabinet interior: adjustable shelves replace the rod and the
          # shelf above it.
          ib = base_info(p)[:bottom_z] + t
          ih = (h - t) - ib
          zs = shelf_positions(ib, ih, p['shelf_count'], t, p['shelf_layout'], p['shelf_spacing'])
          zs.each_with_index do |z, i|
            panel(ents, "#{u}_shelf_#{i + 1}", [t, 0.25, z], [w - 2 * t, d - bt - 0.25, t], m[:shelf])
          end
        else
          if p['include_rod']
            rz = [[p['rod_height'], 12.0].max, h - 3.0].min
            rod(ents, "#{u}_hanging_rod", t, w - t, (d - bt) / 2.0, rz, 1.25, m[:rod])
          end

          if p['top_shelf']
            sz = p['include_rod'] ? [[p['rod_height'], 12.0].max, h - 3.0].min + 2.0 : h - 12.0
            sz = [sz, h - t - 1.0].min
            panel(ents, "#{u}_top_shelf", [t, 0.25, sz], [w - 2 * t, d - bt - 0.25, t], m[:shelf])
          end
        end

        overlay_doors(ents, p, m, u, p['bifold'])
      end

      # One or two full-overlay doors; optional bifold split (each door
      # divided into two leaves). Swing is recorded in the part name:
      # _lh = hinged on the left, _rh = hinged on the right. A pair
      # always swings outward (left door lh, right door rh); a single
      # door follows door_swing.
      def self.overlay_doors(ents, p, m, u, bifold)
        w, h, _d, t = dims(p)
        bi = base_info(p)
        rv = p['reveal']
        nd = p['door_count']
        door_z = bi[:bottom_z] + p['face_bottom_gap']
        door_h = (h - p['face_top_gap']) - door_z
        leaf_gap = 0.0625
        door_w = (w - p['face_left_gap'] - p['face_right_gap'] - (nd - 1) * rv) / nd
        x = p['face_left_gap']
        nd.times do |i|
          swing =
            if nd == 2
              i.zero? ? 'lh' : 'rh'
            else
              p['door_swing'] == 'right' ? 'rh' : 'lh'
            end
          dn = "#{u}_door_#{i + 1}_#{swing}"
          door = ents.add_group
          de = door.entities
          dy = -(t + p['door_gap']) # stand-off from carcass front for hinge/fold clearance
          # Hinge axis on the door's front face at its hinge edge.
          motion = { 'pivot' => [swing == 'lh' ? x : x + door_w, dy],
                     'sign' => swing == 'lh' ? -1 : 1, 'seq' => i }
          if bifold
            half = (door_w - leaf_gap) / 2.0
            leaf_a = panel(de, "#{dn}_leaf_a", [x, dy, door_z],                   [half, t, door_h], m[:face])
            leaf_b = panel(de, "#{dn}_leaf_b", [x + half + leaf_gap, dy, door_z], [half, t, door_h], m[:face])
            # The hinge-side leaf swings; the other folds back against it
            # about their shared back edge, its far edge following the
            # door line. Folded flat at 90 degrees.
            near, far = swing == 'lh' ? [leaf_a, leaf_b] : [leaf_b, leaf_a]
            fold = [swing == 'lh' ? x + half + leaf_gap : x + half, dy + t]
            tag_motion(near, motion.merge('kind' => 'swing', 'max' => 90))
            tag_motion(far,  motion.merge('kind' => 'fold', 'fold' => fold, 'max' => 90))
            componentize(door, dn)
          else
            panel(de, "#{dn}_panel", [x, dy, door_z], [door_w, t, door_h], m[:face])
            tag_motion(componentize(door, dn), motion.merge('kind' => 'swing'))
          end
          x += door_w + rv
        end
      end

      # L-shaped corner unit wrapping an inside room corner with ONE
      # continuous interior. Leg A runs along wall 1 (y = depth); leg B
      # backs onto wall 2 and extends toward the viewer (negative y).
      # Leg lengths are measured along each wall from the room corner to
      # the OUTSIDE of the applied finished ends; height is the overall
      # envelope including the top caps (carcass = height - panel).
      #
      # Fixed construction (the base/construction toggles do not apply):
      #   - each leg is a complete carcass: full-height back on leg A, a
      #     captured back and end side on leg B, a side at leg A's corner
      #     end; a full-height brace panel runs the whole return along
      #     wall 2 behind both backs
      #   - applied finished ends on both outer ends, flush with the door
      #     faces; top cap panels cover each leg out to the door planes
      #   - plinth base: a perimeter rail frame under each leg, set back
      #     to the doors' back plane and faced with toe boards flush with
      #     the door fronts and finished ends
      #
      # Each leg has a single overlay door. The door planes meet at a 90
      # degree outside corner, so one door's edge laps in front of the
      # other: the front door's corner edge stops one reveal clear of the
      # rear door's outer face, while the rear door stops one door gap
      # short of the front door's back plane. The front door must open
      # first (corner_overlay picks it).
      def self.corner_closet(ents, p, m, u)
        d  = p['depth']
        t  = p['panel']
        bt = p['back_thickness']
        h  = p['height'] - t           # carcass height; the caps add t back
        rv = p['reveal']
        g  = p['door_gap']
        bh = p['base_height']
        la = p['leg_a_length']         # envelope, incl. finished end A
        ca = la - t                    # leg A carcass end
        lb = p['leg_b_length'] - d - t # leg B carcass length
        left = p['corner_side'] != 'right'

        min_leg = (d + t + 6.0).round(2)
        raise "Leg B must be at least #{min_leg}\" (depth + panel + 6\")" if lb < 6.0
        raise "Leg A must be at least #{min_leg}\" (depth + panel + 6\")" if la < d + t + 6.0
        raise 'Height too small for the base and top caps' if h - bh - 2 * t < 1.0

        # Geometry is computed for a left corner (leg B at x = 0); a right
        # corner mirrors every part across the unit's vertical midline.
        fx = ->(x0, dx) { left ? x0 : la - x0 - dx }
        box = lambda do |name, o, s, mat|
          panel(ents, "#{u}_#{name}", [fx.call(o[0], s[0]), o[1], o[2]], s, mat)
        end

        # Brace: full-height panel running the whole return along wall 2,
        # behind both legs' backs.
        box.call('wall_brace', [0, -lb, bh], [bt, lb + d, h - bh], m[:back])

        # Each leg is a complete carcass. Back A is full height, covering
        # the rear edges of leg A's sides, top and bottom; back B is
        # captured between leg B's bottom and top.
        box.call('back_a', [bt, d - bt, bh], [ca - bt, bt, h - bh], m[:back])
        box.call('back_b', [bt, -(lb - t), bh + t],
                 [bt, lb - t, h - bh - 2 * t], m[:back])

        # Sides sit on the bottoms and carry the tops.
        box.call('corner_side_a', [bt, 0, bh + t],
                 [t, d - bt, h - bh - 2 * t], m[:carcass])
        box.call('right_side', [ca - t, 0, bh + t],
                 [t, d - bt, h - bh - 2 * t], m[:carcass])
        box.call('end_side_b', [bt, -lb, bh + t],
                 [d - bt, t, h - bh - 2 * t], m[:carcass])

        # Bottoms and tops: two panels each, meeting at y = 0 to form the L.
        box.call('bottom_a', [bt, 0, bh],    [ca - bt, d - bt, t], m[:carcass])
        box.call('bottom_b', [bt, -lb, bh],  [d - bt, lb, t],      m[:carcass])
        box.call('top_a', [bt, 0, h - t],    [ca - bt, d - bt, t], m[:carcass])
        box.call('top_b', [bt, -lb, h - t],  [d - bt, lb, t],      m[:carcass])

        # Applied finished ends on the exposed outer ends, flush with the
        # door fronts; top caps cover each leg's full footprint out to the
        # door planes and over the finished ends.
        fd = d + t + g # footprint depth: wall to door face / finished end
        box.call('finished_end_a', [ca, -(t + g), bh], [t, fd, h - bh], m[:face])
        box.call('finished_end_b', [0, -(lb + t), bh], [fd, t, h - bh], m[:face])
        box.call('top_cap_a', [fd, -(t + g), h], [la - fd, fd, t],      m[:face])
        box.call('top_cap_b', [0, -(lb + t), h], [fd, lb + t + d, t],   m[:face])

        # Plinth: a perimeter rail frame under each leg, set back to the
        # doors' back plane and extending under the finished ends, faced
        # with toe boards flush with the door fronts and finished ends. The
        # rails stop one panel short of the base height and carry top
        # panels that the carcass sits on; the toe boards run full height.
        if bh > 0
          bn = "#{u}_base"
          base = ents.add_group
          be = base.entities
          rb = lambda do |name, o, s, mat = m[:carcass]|
            panel(be, "#{bn}_#{name}", [fx.call(o[0], s[0]), o[1], o[2]], s, mat)
          end
          rh = bh >= t ? bh - t : bh # rail height under the top panels
          if rh > 0
            rb.call('wall_2',   [0, -(lb + t), 0],  [t, lb + t + d, rh])
            rb.call('wall_1_b', [t, d - t, 0],      [d + g - t, t, rh])
            rb.call('wall_1_a', [d + g, d - t, 0],  [la - d - g, t, rh])
            rb.call('end_b',   [t, -(lb + t), 0],   [d + g - t, t, rh])
            rb.call('front_b', [d + g - t, -lb, 0], [t, lb + d - t, rh])
            rb.call('front_a', [d + g, -g, 0],      [la - d - g, t, rh])
            rb.call('end_a',   [la - t, t - g, 0],  [t, d + g - 2 * t, rh])
            # Leg A's own corner-end rail, against front_b, so leg A's box
            # has four rails of its own.
            rb.call('corner_a', [d + g, t - g, 0],  [t, d + g - 2 * t, rh])
          end
          if bh >= t
            # Tops follow the front rails, butting the toe boards. Top B
            # covers leg B and the corner square; top A covers the rest of
            # leg A, the seam landing on front_b / corner_a.
            rb.call('top_b', [0, -(lb + t), rh],   [d + g, lb + t + d, t])
            rb.call('top_a', [d + g, -g, rh],      [la - d - g, d + g, t])
          end
          rb.call('toe_a', [d + t + g, -(t + g), 0],
                  [la - d - t - g, t, bh], m[:face])
          rb.call('toe_b', [d + g, -(lb + t), 0], [t, lb + t - g, bh], m[:face])
          componentize(base, bn)
        end

        # Rods: leg A's runs between its corner side and outer side; leg
        # B's stops at leg A's front plane. They sit at different y/x so
        # they clear each other even at the same height.
        if p['leg_a_rod']
          rz = [[p['leg_a_rod_height'], 12.0].max, h - 3.0].min
          x0 = left ? bt + t : 2 * t
          x1 = left ? ca - t : la - bt - t
          rod(ents, "#{u}_hanging_rod_a", x0, x1, (d - bt) / 2.0, rz, 1.25, m[:rod])
        end
        if p['leg_b_rod']
          rz = [[p['leg_b_rod_height'], 12.0].max, h - 3.0].min
          xc = fx.call((d + 2 * bt) / 2.0, 0.0)
          rod_y(ents, "#{u}_hanging_rod_b", -lb + t, 0.0, xc, rz, 1.25, m[:rod])
        end

        # Shelves above the rods (or near the top without one).
        if p['leg_a_shelf']
          sz = p['leg_a_rod'] ? [[p['leg_a_rod_height'], 12.0].max, h - 3.0].min + 2.0 : h - 12.0
          sz = [sz, h - t - 1.0].min
          box.call('top_shelf_a', [bt + t, 0.25, sz],
                   [ca - bt - 2 * t, d - bt - 0.25, t], m[:shelf])
        end
        if p['leg_b_shelf']
          sz = p['leg_b_rod'] ? [[p['leg_b_rod_height'], 12.0].max, h - 3.0].min + 2.0 : h - 12.0
          sz = [sz, h - t - 1.0].min
          box.call('top_shelf_b', [2 * bt, -lb + t, sz],
                   [d - 2 * bt - 0.25, lb - t, t], m[:shelf])
        end

        # Single overlay door per leg. The front (over) door's corner edge
        # stops one reveal clear of the rear door's outer face; the rear
        # door stops one door gap short of the front door's back plane, so
        # the front door must open first. With only one door it runs to
        # the carcass corner plane.
        door_z = bh + p['face_bottom_gap']
        door_h = (h - p['face_top_gap']) - door_z
        og_a = left ? p['face_right_gap'] : p['face_left_gap'] # leg A outer end
        og_b = left ? p['face_left_gap'] : p['face_right_gap'] # leg B outer end
        a_front = p['corner_overlay'] != 'leg_b'
        # Each door hinges on its front face at its leg's outer end. The
        # front door opens first; the rear one waits until it is fully
        # open ('lag' is a fraction of the animation duration).
        both = p['leg_a_doors'] && p['leg_b_doors']
        order = ->(front) { front || !both ? { 'seq' => 0 } : { 'seq' => 1, 'lag' => 1.0 } }
        ms = left ? 1 : -1 # mirroring reverses the swing
        if p['leg_a_doors']
          xa_min =
            if p['leg_b_doors']
              a_front ? d + g + t + rv : d + 2 * g
            else
              d
            end
          wa = ca - og_a - xa_min
          raise 'Leg A too short for its door' if wa < 3.0
          door = box.call('door_a', [xa_min, -(t + g), door_z], [wa, t, door_h], m[:face])
          tag_motion(door, order.call(a_front).merge(
            'kind' => 'swing', 'pivot' => [fx.call(ca - og_a, 0.0), -(t + g)], 'sign' => ms
          ))
        end
        if p['leg_b_doors']
          yb_max =
            if p['leg_a_doors']
              a_front ? -2 * g : -(t + g) - rv
            else
              0.0
            end
          yb_min = -lb + og_b
          wb = yb_max - yb_min
          raise 'Leg B too short for its door' if wb < 3.0
          door = box.call('door_b', [d + g, yb_min, door_z], [t, wb, door_h], m[:face])
          tag_motion(door, order.call(!a_front).merge(
            'kind' => 'swing', 'pivot' => [fx.call(d + g + t, 0.0), yb_min], 'sign' => -ms
          ))
        end
      end

      def self.cubby(ents, p, m, u)
        w, h, d, t = dims(p)
        bt = p['back_thickness']
        bi = base_info(p)
        carcass(ents, p, m, u)

        iw = w - 2 * t
        ib = bi[:bottom_z] + t
        ih = (h - t) - ib
        sb = p['shelf_depth'] # setback from the front; 0 = flush with the carcass
        sd = d - bt - sb
        raise 'Shelf depth too large for the unit depth' if sd < 1.0

        n = p['shelf_count']
        if n > 0
          spacing = ih / (n + 1)
          n.times do |i|
            z = ib + spacing * (i + 1)
            panel(ents, "#{u}_shelf_#{i + 1}", [t, sb, z], [iw, sd, t], m[:shelf])
          end
        end

        nd = p['divider_count']
        if nd > 0
          spacing = iw / (nd + 1)
          nd.times do |i|
            x = t + spacing * (i + 1) - t / 2.0
            panel(ents, "#{u}_divider_#{i + 1}", [x, sb, ib], [t, sd, ih], m[:carcass])
          end
        end

        overlay_doors(ents, p, m, u, false) if p['cubby_doors']
      end

      # ------------------------------------------------------------------
      # Shared construction
      # ------------------------------------------------------------------

      def self.carcass(ents, p, m, u)
        w, h, d, t = dims(p)
        bt = p['back_thickness']
        bi = base_info(p)
        bh = p['base_height']
        full_back = p['back_full']

        # With a full back, the back panel covers the rear edges of the
        # sides and top, so those panels stop short of the rear by bt.
        rear = full_back ? d - bt : d

        # Bottom under the sides (default): full-width bottom panel, the
        # sides rest on top of it. Not applicable with a toe kick, where
        # the sides must run to the floor (bottom stays captured).
        bottom_under = p['bottom_under_sides'] && p['base_type'] != 'toe_kick'
        side_z0 = bottom_under ? bi[:bottom_z] + t : bi[:side_z0]

        side_top = p['top_on_sides'] ? h - t : h
        panel(ents, "#{u}_left_side",  [0, 0, side_z0],     [t, rear, side_top - side_z0], m[:carcass])
        panel(ents, "#{u}_right_side", [w - t, 0, side_z0], [t, rear, side_top - side_z0], m[:carcass])

        if bottom_under
          panel(ents, "#{u}_bottom", [0, 0, bi[:bottom_z]], [w, rear, t], m[:carcass])
        else
          panel(ents, "#{u}_bottom", [t, 0, bi[:bottom_z]], [w - 2 * t, d - bt, t], m[:carcass])
        end

        if p['top_on_sides']
          panel(ents, "#{u}_top", [0, 0, h - t], [w, rear, t], m[:carcass])
        else
          panel(ents, "#{u}_top", [t, 0, h - t], [w - 2 * t, d - bt, t], m[:carcass])
        end

        if full_back
          # Full height/width: covers the sides, top and bottom from behind.
          back_z0 = [side_z0, bi[:bottom_z]].min
          panel(ents, "#{u}_back", [0, d - bt, back_z0],
                [w, bt, h - back_z0], m[:back])
        else
          back_top = p['top_on_sides'] ? h - t : h
          back_z0  = bottom_under ? bi[:bottom_z] + t : bi[:bottom_z]
          panel(ents, "#{u}_back", [t, d - bt, back_z0],
                [w - 2 * t, bt, back_top - back_z0], m[:back])
        end

        case p['base_type']
        when 'toe_kick'
          panel(ents, "#{u}_toe_kick", [t, 2.5, 0], [w - 2 * t, t, bh], m[:carcass]) if bh > 0
        when 'riser'
          if bh > 0
            rn = "#{u}_riser"
            riser = ents.add_group
            re = riser.entities
            rail_h = p['riser_top'] ? bh - t : bh
            # Optional decorative face on the fronts' plane (less any
            # set-back); the front rail moves out to back it directly.
            ry = 0.0
            if p['riser_face']
              fy = [face_plane(p) + p['riser_face_setback'], d - 3 * t].min
              lg = p['riser_face_left_gap']
              rg = p['riser_face_right_gap']
              panel(re, "#{rn}_face", [lg, fy, 0], [w - lg - rg, t, bh], m[:face])
              ry = fy + t
            end
            if rail_h > 0
              panel(re, "#{rn}_front", [0, ry, 0],         [w, t, rail_h],              m[:carcass])
              panel(re, "#{rn}_back",  [0, d - t, 0],      [w, t, rail_h],              m[:carcass])
              panel(re, "#{rn}_left",  [0, ry + t, 0],     [t, d - 2 * t - ry, rail_h], m[:carcass])
              panel(re, "#{rn}_right", [w - t, ry + t, 0], [t, d - 2 * t - ry, rail_h], m[:carcass])
            end
            if p['riser_top'] && bh >= t
              # Top panel rests on the riser rails; carcass sits on it.
              # Its front edge follows the front rail, butting the face.
              panel(re, "#{rn}_top", [0, ry, bh - t], [w, d - ry, t], m[:carcass])
            end
            componentize(riser, rn)
          end
        end
      end

      # Convert a populated group into a component whose definition gets
      # +name+. Every part is its own definition so the hierarchical name
      # shows in the Outliner, Entity Info, and cutlist extensions.
      def self.componentize(group, name)
        inst = group.to_component
        defn = inst.definition
        defn.name = defn.model.definitions.unique_name(name)
        inst
      end

      # Record how a door / drawer part moves, for the animator (see
      # animation.rb). Coordinates are the unit's; parts rest at identity.
      def self.tag_motion(inst, motion)
        inst.set_attribute(DICT, 'motion', motion.to_json)
        inst
      end

      # Axis-aligned rectangular panel as a named component.
      def self.panel(ents, name, origin, size, material)
        x, y, z = origin
        dx, dy, dz = size
        g = ents.add_group
        face = g.entities.add_face(
          [x, y, z], [x + dx, y, z], [x + dx, y + dy, z], [x, y + dy, z]
        )
        face.reverse! if face.normal.z < 0
        face.pushpull(dz)
        c = componentize(g, name)
        c.material = material
        c
      end

      # Cylinder along the X axis.
      def self.rod(ents, name, x0, x1, y, z, dia, material)
        g = ents.add_group
        ge = g.entities
        edges = ge.add_circle(Geom::Point3d.new(x0, y, z),
                              Geom::Vector3d.new(1, 0, 0), dia / 2.0, 24)
        face = ge.add_face(edges)
        face.reverse! if face.normal.x < 0
        face.pushpull(x1 - x0)
        c = componentize(g, name)
        c.material = material
        c
      end

      # Cylinder along the Y axis.
      def self.rod_y(ents, name, y0, y1, x, z, dia, material)
        g = ents.add_group
        ge = g.entities
        edges = ge.add_circle(Geom::Point3d.new(x, y0, z),
                              Geom::Vector3d.new(0, 1, 0), dia / 2.0, 24)
        face = ge.add_face(edges)
        face.reverse! if face.normal.y < 0
        face.pushpull(y1 - y0)
        c = componentize(g, name)
        c.material = material
        c
      end

      # ------------------------------------------------------------------
      # Layout helpers
      # ------------------------------------------------------------------

      def self.dims(p)
        [p['width'], p['height'], p['depth'], p['panel']]
      end

      # bottom_z = z of the underside of the bottom panel,
      # side_z0  = z where the side panels start.
      def self.base_info(p)
        bh = p['base_height']
        case p['base_type']
        when 'toe_kick' then { bottom_z: bh, side_z0: 0.0 }
        when 'riser'    then { bottom_z: bh, side_z0: bh }
        else                 { bottom_z: 0.0, side_z0: 0.0 }
        end
      end

      # Y of the front-most surface of the unit's fronts (drawer faces or
      # doors). Overlay fronts stand off the carcass front; inset faces
      # are flush with the carcass front edge. The riser face is built on
      # this plane (plus any set-back).
      def self.face_plane(p)
        t = p['panel']
        case p['type']
        when 'closet'      then -(t + p['door_gap'])
        when 'cubby'       then p['cubby_doors'] ? -(t + p['door_gap']) : -(t + p['face_gap'])
        when 'drawer_bank' then p['front_style'] == 'inset' ? 0.0 : -(t + p['face_gap'])
        else                    -(t + p['face_gap'])
        end
      end

      # Bottom z of each shelf in an interior starting at +ib+, +ih+ tall.
      #   even   - shelves split the interior into equal clear openings
      #   center - shelves stacked symmetrically about mid-height, +spacing+
      #            clear between neighbours (one shelf sits dead centre)
      def self.shelf_positions(ib, ih, n, t, layout, spacing)
        return [] if n < 1
        raise "Unit too short for #{n} shelves" if ih < n * t + (n + 1) * 1.0
        if layout == 'center'
          pitch = spacing + t
          stack = (n - 1) * pitch + t
          raise "Shelf spacing too large for #{n} shelves" if stack > ih
          mid = ib + ih / 2.0
          Array.new(n) { |i| mid + (i - (n - 1) / 2.0) * pitch - t / 2.0 }
        else
          gap = (ih - n * t) / (n + 1)
          Array.new(n) { |i| ib + gap * (i + 1) + t * i }
        end
      end

      # Face heights, returned bottom -> top (build order).
      # Custom heights are entered top -> bottom; nil entries share the
      # remaining space; the result is scaled to fit exactly.
      def self.resolve_heights(avail, n, p)
        case p['height_mode']
        when 'custom'
          arr = (p['custom_heights'] || [])[0, n]
          arr = arr + Array.new(n - arr.size, nil)
          autos = arr.count(nil)
          fixed = arr.compact.inject(0.0, :+)
          if autos > 0
            rem = [avail - fixed, autos * 1.0].max
            arr = arr.map { |v| v || rem / autos }
          end
          sum = arr.inject(0.0, :+)
          arr = arr.map { |v| v * avail / sum } if (sum - avail).abs > 1e-6
          arr.reverse
        when 'graduated'
          weights = Array.new(n) { |j| 1.0 + 0.15 * (n - 1 - j) } # j=0 is bottom
          s = weights.inject(:+)
          weights.map { |wt| avail * wt / s }
        else
          Array.new(n, avail / n)
        end
      end

      # [sx, sy, sz] scale factors of an instance's transformation
      # (component-local: x = width, y = depth, z = height).
      def self.scale_factors(instance)
        a = instance.transformation.to_a
        [Geom::Vector3d.new(a[0], a[1], a[2]).length.to_f,
         Geom::Vector3d.new(a[4], a[5], a[6]).length.to_f,
         Geom::Vector3d.new(a[8], a[9], a[10]).length.to_f]
      end

      # Lowest free {type}_{n} definition name; the unit name prefixes
      # every part name inside it.
      def self.unit_name(model, type)
        base = %w[drawer_bank closet corner_closet cubby].include?(type) ? type : 'cb_unit'
        n = 1
        n += 1 while model.definitions["#{base}_#{n}"]
        "#{base}_#{n}"
      end

      # Clear a unit definition for rebuild, removing the now-unused part
      # definitions left behind (each part is its own definition). Parts
      # the user copied elsewhere still have instances and are kept.
      def self.purge_parts(definition)
        model = definition.model
        defs = []
        collect = lambda do |ents|
          ents.grep(Sketchup::ComponentInstance).each do |ci|
            defs << ci.definition
            collect.call(ci.definition.entities)
          end
        end
        collect.call(definition.entities)
        definition.entities.clear!
        return unless model.definitions.respond_to?(:remove)
        # Parents precede their children, so each is instance-free by the
        # time it is reached.
        defs.uniq.each do |dn|
          model.definitions.remove(dn) if dn.valid? && dn.instances.empty?
        end
      end

      # Place new units to the right of existing Closet Builder units.
      def self.next_placement(model)
        max_x = 0.0
        model.active_entities.grep(Sketchup::ComponentInstance).each do |inst|
          next unless inst.attribute_dictionary(DICT)
          max_x = [max_x, inst.bounds.max.x + 3.0].max
        end
        Geom::Point3d.new(max_x, 0, 0)
      end

      # ------------------------------------------------------------------
      # Param normalization (with back-compat for v1.0 saved params)
      # ------------------------------------------------------------------
      def self.normalize(p)
        q = {}
        q['type']           = p['type'].to_s
        q['width']          = clamp(p['width'].to_f,  6.0, 240.0)
        q['height']         = clamp(p['height'].to_f, 6.0, 144.0)
        q['depth']          = clamp(p['depth'].to_f,  4.0, 48.0)
        q['panel']          = clamp(p['panel'].to_f, 0.25, 1.5)
        q['back_match']     = p.key?('back_match') ? truthy(p['back_match']) : !p.key?('back_thickness')
        q['back_thickness'] = q['back_match'] ? q['panel'] : clamp(p['back_thickness'].to_f, 0.125, 1.5)
        q['box_thickness']    = clamp(num(p, 'box_thickness',    0.5), 0.25,  1.0)
        q['bottom_thickness'] = clamp(num(p, 'bottom_thickness', 0.5), 0.125, 1.0)

        # Base (v1.0 params only had 'toe_kick' height)
        q['base_type'] =
          if %w[none toe_kick riser].include?(p['base_type'])
            p['base_type']
          else
            p['toe_kick'].to_f > 0 ? 'toe_kick' : 'none'
          end
        q['base_height'] = clamp(num(p, 'base_height', p['toe_kick'].to_f), 0.0, 18.0)
        # Corner closets always build their plinth; the base-type select is
        # hidden on that tab and may hold a stale value from another tab.
        q['base_height'] = 0.0 if q['base_type'] == 'none' && q['type'] != 'corner_closet'

        q['top_on_sides'] = p.key?('top_on_sides') ? truthy(p['top_on_sides']) : true
        q['back_full']    = p.key?('back_full')    ? truthy(p['back_full'])    : true
        q['bottom_under_sides'] = p.key?('bottom_under_sides') ? truthy(p['bottom_under_sides']) : true
        q['riser_top']    = p.key?('riser_top')    ? truthy(p['riser_top'])    : true
        q['riser_face']   = truthy(p['riser_face'])
        q['riser_face_setback'] = clamp(num(p, 'riser_face_setback', 0.0), 0.0, 12.0)
        q['door_gap']     = clamp(num(p, 'door_gap', 0.25), 0.0, 2.0)
        q['face_gap']     = clamp(num(p, 'face_gap', 0.25), 0.0, 2.0)

        # Fronts
        q['front_style'] = p['front_style'] == 'inset' ? 'inset' : 'overlay'
        q['reveal']      = clamp(num(p, 'reveal', 0.125), 0.03125, 1.0)
        side_seed             = num(p, 'side_gap', 0.0) # v1.x combined key
        q['face_left_gap']    = clamp(num(p, 'face_left_gap',   side_seed), 0.0, 4.0)
        q['face_right_gap']   = clamp(num(p, 'face_right_gap',  side_seed), 0.0, 4.0)
        q['face_top_gap']     = clamp(num(p, 'face_top_gap',    0.0), 0.0, 4.0)
        q['face_bottom_gap']  = clamp(num(p, 'face_bottom_gap', 0.0), 0.0, 4.0)
        # Riser face side insets (older units followed the face edge gaps)
        q['riser_face_left_gap']  = clamp(num(p, 'riser_face_left_gap',  q['face_left_gap']),  0.0, 4.0)
        q['riser_face_right_gap'] = clamp(num(p, 'riser_face_right_gap', q['face_right_gap']), 0.0, 4.0)

        # Drawers
        q['drawer_count'] = clamp(p['drawer_count'].to_i, 1, 12)
        q['height_mode'] =
          if %w[equal graduated custom].include?(p['height_mode'])
            p['height_mode']
          else
            truthy(p['graduated']) ? 'graduated' : 'equal'
          end
        q['custom_heights'] = Array(p['custom_heights']).map do |v|
          (v.nil? || v.to_s.strip.empty?) ? nil : clamp(v.to_f, 0.5, 60.0)
        end

        # Drawer box clearances (box_side_gap is the v1.1 combined key)
        side_default        = num(p, 'box_side_gap', 0.5)
        q['box_left_gap']   = clamp(num(p, 'box_left_gap',  side_default), 0.0, 4.0)
        q['box_right_gap']  = clamp(num(p, 'box_right_gap', side_default), 0.0, 4.0)
        q['box_rear_gap']   = clamp(num(p, 'box_rear_gap',   1.0), 0.0, 6.0)
        q['box_bottom_gap'] = clamp(num(p, 'box_bottom_gap', 1.0),   0.0, 6.0)
        q['box_top_gap']    = clamp(num(p, 'box_top_gap',    0.625), 0.0, 6.0)
        q['box_depth']      = clamp(num(p, 'box_depth', 0.0), 0.0, 48.0) # 0 = auto

        # Captured bottom (groove/rabbet); depth limited to wall thickness
        q['bottom_groove']       = p.key?('bottom_groove') ? truthy(p['bottom_groove']) : true
        q['bottom_groove_depth'] = clamp(num(p, 'bottom_groove_depth', 0.1875), 0.0, 0.5)

        # Closet / cubby
        q['door_count']    = p['door_count'].to_i == 1 ? 1 : 2
        q['door_swing']    = p['door_swing'] == 'right' ? 'right' : 'left'
        q['include_rod']   = truthy(p['include_rod'])
        q['rod_height']    = clamp(num(p, 'rod_height', 66.0), 12.0, 120.0)
        q['top_shelf']     = truthy(p['top_shelf'])
        q['bifold']        = truthy(p['bifold'])
        q['closet_interior'] = p['closet_interior'] == 'shelves' ? 'shelves' : 'rod'
        q['shelf_layout']    = p['shelf_layout'] == 'center' ? 'center' : 'even'
        q['shelf_spacing']   = clamp(num(p, 'shelf_spacing', 12.0), 1.0, 60.0)
        q['shelf_count']   = clamp(p['shelf_count'].to_i, 0, 20)
        q['divider_count'] = clamp(p['divider_count'].to_i, 0, 10)
        q['shelf_depth']   = clamp(num(p, 'shelf_depth', 0.0), 0.0, 24.0)
        q['cubby_doors']   = truthy(p['cubby_doors'])

        # Corner closet
        q['corner_side']      = p['corner_side'] == 'right' ? 'right' : 'left'
        q['corner_overlay']   = p['corner_overlay'] == 'leg_b' ? 'leg_b' : 'leg_a'
        q['leg_a_length']     = clamp(num(p, 'leg_a_length', p['width'].to_f), 12.0, 240.0)
        q['leg_b_length']     = clamp(num(p, 'leg_b_length', 48.0), 12.0, 240.0)
        q['leg_a_rod']        = p.key?('leg_a_rod')   ? truthy(p['leg_a_rod'])   : true
        q['leg_b_rod']        = p.key?('leg_b_rod')   ? truthy(p['leg_b_rod'])   : true
        q['leg_a_rod_height'] = clamp(num(p, 'leg_a_rod_height', 66.0), 12.0, 120.0)
        q['leg_b_rod_height'] = clamp(num(p, 'leg_b_rod_height', 66.0), 12.0, 120.0)
        q['leg_a_shelf']      = p.key?('leg_a_shelf') ? truthy(p['leg_a_shelf']) : true
        q['leg_b_shelf']      = p.key?('leg_b_shelf') ? truthy(p['leg_b_shelf']) : true
        q['leg_a_doors']      = p.key?('leg_a_doors') ? truthy(p['leg_a_doors']) : true
        q['leg_b_doors']      = p.key?('leg_b_doors') ? truthy(p['leg_b_doors']) : true

        %w[mat_carcass mat_face mat_box mat_back mat_shelf mat_bottom].each { |k| q[k] = p[k].to_s }
        q
      end

      def self.num(p, key, default)
        v = p[key]
        (v.nil? || v.to_s.strip.empty?) ? default.to_f : v.to_f
      end

      def self.truthy(v)
        v == true || v == 'true' || v == 1
      end

      def self.clamp(v, lo, hi)
        [[v, lo].max, hi].min
      end
    end
  end
end
