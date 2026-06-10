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
#   riser    - separate plinth box; whole carcass (incl. sides) sits on top of it
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
          definition.entities.clear!
          # Drop any Scale-tool scaling: geometry is rebuilt at true size,
          # keeping the unit's position and rotation.
          tr = instance.transformation
          instance.transformation = Geom::Transformation.axes(
            tr.origin, tr.xaxis.normalize, tr.yaxis.normalize, tr.zaxis.normalize
          )
        else
          name = base_name(params['type'])
          name = model.definitions.unique_name(name) if model.definitions.respond_to?(:unique_name)
          definition = model.definitions.add(name)
          tr = Geom::Transformation.new(next_placement(model))
          instance = model.active_entities.add_instance(definition, tr)
        end

        mats = Materials.role_materials(model, params)
        case params['type']
        when 'drawer_bank' then drawer_bank(definition.entities, params, mats)
        when 'closet'      then closet_section(definition.entities, params, mats)
        when 'cubby'       then cubby(definition.entities, params, mats)
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

      def self.drawer_bank(ents, p, m)
        w, h, d, t = dims(p)
        bi = base_info(p)
        carcass(ents, p, m)

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
          drawer = ents.add_group
          drawer.name = "Drawer #{i + 1}"
          de = drawer.entities

          panel(de, 'Face', [x0, fy, z], [fw, t, fh], m[:face])

          # Drawer box. Clearances to the carcass are configurable:
          #   box_left_gap / box_right_gap - per side (slides)
          #   box_rear_gap   - to the back panel
          #   box_bottom_gap - lowest box above the carcass bottom
          #   box_top_gap    - top box below the carcass top
          bw = iw - p['box_left_gap'] - p['box_right_gap']
          bd = id_ - p['box_rear_gap']
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
          box = de.add_group
          box.name = 'Box'
          be = box.entities
          panel(be, 'Box Left',   [bx, 0, bz],             [bo, bd, bh],            m[:box])
          panel(be, 'Box Right',  [bx + bw - bo, 0, bz],   [bo, bd, bh],            m[:box])
          panel(be, 'Box Front',  [bx + bo, 0, bz],        [bw - 2 * bo, bo, bh],   m[:box])
          panel(be, 'Box Back',   [bx + bo, bd - bo, bz],  [bw - 2 * bo, bo, bh],   m[:box])
          panel(be, 'Box Bottom', [bx + bo, bo, bz + bo],
                [bw - 2 * bo, bd - 2 * bo, bot], m[:bottom])

          z += fh + rv
        end
      end

      def self.closet_section(ents, p, m)
        w, h, d, t = dims(p)
        bt = p['back_thickness']
        bi = base_info(p)
        carcass(ents, p, m)

        if p['include_rod']
          rz = [[p['rod_height'], 12.0].max, h - 3.0].min
          rod(ents, 'Hanging Rod', t, w - t, (d - bt) / 2.0, rz, 1.25, m[:rod])
        end

        if p['top_shelf']
          sz = p['include_rod'] ? [[p['rod_height'], 12.0].max, h - 3.0].min + 2.0 : h - 12.0
          sz = [sz, h - t - 1.0].min
          panel(ents, 'Top Shelf', [t, 0.25, sz], [w - 2 * t, d - bt - 0.25, t], m[:shelf])
        end

        # Two full-overlay doors; optional bifold split (each leaf halved)
        rv = p['reveal']
        door_z = bi[:bottom_z] + p['face_bottom_gap']
        door_h = (h - p['face_top_gap']) - door_z
        leaf_gap = 0.0625
        door_w = (w - p['face_left_gap'] - p['face_right_gap'] - rv) / 2.0
        x = p['face_left_gap']
        2.times do |i|
          door = ents.add_group
          door.name = "Door #{i + 1}"
          de = door.entities
          dy = -(t + p['door_gap']) # stand-off from carcass front for hinge/fold clearance
          if p['bifold']
            half = (door_w - leaf_gap) / 2.0
            panel(de, 'Leaf A', [x, dy, door_z],                   [half, t, door_h], m[:face])
            panel(de, 'Leaf B', [x + half + leaf_gap, dy, door_z], [half, t, door_h], m[:face])
          else
            panel(de, 'Panel', [x, dy, door_z], [door_w, t, door_h], m[:face])
          end
          x += door_w + rv
        end
      end

      def self.cubby(ents, p, m)
        w, h, d, t = dims(p)
        bt = p['back_thickness']
        bi = base_info(p)
        carcass(ents, p, m)

        iw = w - 2 * t
        ib = bi[:bottom_z] + t
        ih = (h - t) - ib
        sd = d - bt - 0.25 # shelves/dividers held back 1/4" from front

        n = p['shelf_count']
        if n > 0
          spacing = ih / (n + 1)
          n.times do |i|
            z = ib + spacing * (i + 1)
            panel(ents, "Shelf #{i + 1}", [t, 0.25, z], [iw, sd, t], m[:shelf])
          end
        end

        nd = p['divider_count']
        if nd > 0
          spacing = iw / (nd + 1)
          nd.times do |i|
            x = t + spacing * (i + 1) - t / 2.0
            panel(ents, "Divider #{i + 1}", [x, 0.25, ib], [t, sd, ih], m[:carcass])
          end
        end
      end

      # ------------------------------------------------------------------
      # Shared construction
      # ------------------------------------------------------------------

      def self.carcass(ents, p, m)
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
        panel(ents, 'Left Side',  [0, 0, side_z0],     [t, rear, side_top - side_z0], m[:carcass])
        panel(ents, 'Right Side', [w - t, 0, side_z0], [t, rear, side_top - side_z0], m[:carcass])

        if bottom_under
          panel(ents, 'Bottom', [0, 0, bi[:bottom_z]], [w, rear, t], m[:carcass])
        else
          panel(ents, 'Bottom', [t, 0, bi[:bottom_z]], [w - 2 * t, d - bt, t], m[:carcass])
        end

        if p['top_on_sides']
          panel(ents, 'Top', [0, 0, h - t], [w, rear, t], m[:carcass])
        else
          panel(ents, 'Top', [t, 0, h - t], [w - 2 * t, d - bt, t], m[:carcass])
        end

        if full_back
          # Full height/width: covers the sides, top and bottom from behind.
          back_z0 = [side_z0, bi[:bottom_z]].min
          panel(ents, 'Back', [0, d - bt, back_z0],
                [w, bt, h - back_z0], m[:back])
        else
          back_top = p['top_on_sides'] ? h - t : h
          back_z0  = bottom_under ? bi[:bottom_z] + t : bi[:bottom_z]
          panel(ents, 'Back', [t, d - bt, back_z0],
                [w - 2 * t, bt, back_top - back_z0], m[:back])
        end

        case p['base_type']
        when 'toe_kick'
          panel(ents, 'Toe Kick', [t, 2.5, 0], [w - 2 * t, t, bh], m[:carcass]) if bh > 0
        when 'riser'
          if bh > 0
            riser = ents.add_group
            riser.name = 'Riser'
            re = riser.entities
            rail_h = p['riser_top'] ? bh - t : bh
            if rail_h > 0
              panel(re, 'Riser Front', [0, 0, 0],     [w, t, rail_h],         m[:carcass])
              panel(re, 'Riser Back',  [0, d - t, 0], [w, t, rail_h],         m[:carcass])
              panel(re, 'Riser Left',  [0, t, 0],     [t, d - 2 * t, rail_h], m[:carcass])
              panel(re, 'Riser Right', [w - t, t, 0], [t, d - 2 * t, rail_h], m[:carcass])
            end
            if p['riser_top'] && bh >= t
              # Top panel rests on the riser rails; carcass sits on it.
              panel(re, 'Riser Top', [0, 0, bh - t], [w, d, t], m[:carcass])
            end
          end
        end
      end

      # Axis-aligned rectangular panel as a named group.
      def self.panel(ents, name, origin, size, material)
        x, y, z = origin
        dx, dy, dz = size
        g = ents.add_group
        face = g.entities.add_face(
          [x, y, z], [x + dx, y, z], [x + dx, y + dy, z], [x, y + dy, z]
        )
        face.reverse! if face.normal.z < 0
        face.pushpull(dz)
        g.name = name
        g.material = material
        g
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
        g.name = name
        g.material = material
        g
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

      def self.base_name(type)
        { 'drawer_bank' => 'CB Drawer Bank',
          'closet'      => 'CB Closet Section',
          'cubby'       => 'CB Cubby' }[type] || 'CB Unit'
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
        q['base_height'] = 0.0 if q['base_type'] == 'none'

        q['top_on_sides'] = p.key?('top_on_sides') ? truthy(p['top_on_sides']) : true
        q['back_full']    = p.key?('back_full')    ? truthy(p['back_full'])    : true
        q['bottom_under_sides'] = p.key?('bottom_under_sides') ? truthy(p['bottom_under_sides']) : true
        q['riser_top']    = p.key?('riser_top')    ? truthy(p['riser_top'])    : true
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

        # Closet / cubby
        q['include_rod']   = truthy(p['include_rod'])
        q['rod_height']    = clamp(num(p, 'rod_height', 66.0), 12.0, 120.0)
        q['top_shelf']     = truthy(p['top_shelf'])
        q['bifold']        = truthy(p['bifold'])
        q['shelf_count']   = clamp(p['shelf_count'].to_i, 0, 20)
        q['divider_count'] = clamp(p['divider_count'].to_i, 0, 10)

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
