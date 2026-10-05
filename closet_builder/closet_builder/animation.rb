# Closet Builder - door and drawer animation.
#
# The builders tag each moving part with a 'motion' attribute (JSON) in the
# unit's coordinates; parts rest at the identity transformation:
#   swing - a door, or a bifold's hinge-side leaf: turns about the vertical
#           axis through 'pivot' (front face, hinge edge); 'sign' is the
#           opening sense about +Z, 'max' an optional cap in degrees
#   fold  - a bifold's other leaf: hinged to the swing leaf at 'fold'
#           (their shared back edge), it folds back twice as far so the
#           leaves close up like a bifold
#   slide - a drawer: pulls straight out (-Y), up to 'travel' (box depth)
# 'seq' orders a unit's parts (opening order; closing runs it backwards).
# 'lag', a fraction of the duration, holds a door until the ones before it
# are open, and it stops short of touching them (the corner closet's rear
# door, whose swing can be blocked by the open front door).
#
# Frames move parts with move!, outside the undo stack. When an animation
# ends, its parts are rewound and set to their final pose in one
# operation, so Undo returns them to where they started.

require 'json'

module AJL
  module ClosetBuilder
    module Animation
      PREFS = 'AJL_ClosetBuilder_Animation'.freeze
      DEFAULTS = {
        'door_angle'       => 90.0,  # degrees
        'drawer_extension' => 100.0, # percent of the box depth
        'duration'         => 1.0,   # seconds per part
        'stagger'          => 0.15,  # seconds between parts starting
        'easing'           => 'smooth',
        'loop'             => false
      }.freeze
      LIMITS = {
        'door_angle' => [5.0, 170.0], 'drawer_extension' => [5.0, 100.0],
        'duration'   => [0.1, 10.0],  'stagger'          => [0.0, 5.0]
      }.freeze
      EASINGS = %w[smooth soft linear].freeze
      HOLD = 1.0 # seconds Play pauses open (and closed, between loops)

      # ------------------------------------------------------------------
      # Settings: per user, shared by every unit and model
      # ------------------------------------------------------------------

      def self.settings
        normalize(DEFAULTS.keys.map { |k| [k, Sketchup.read_default(PREFS, k)] }.to_h)
      end

      def self.save_settings(raw)
        s = normalize(raw)
        s.each { |k, v| Sketchup.write_default(PREFS, k, v) }
        s
      end

      def self.normalize(raw)
        s = LIMITS.map do |k, (lo, hi)|
          [k, Builders.clamp(Builders.num(raw, k, DEFAULTS[k]), lo, hi)]
        end.to_h
        s['easing'] = EASINGS.include?(raw['easing']) ? raw['easing'] : DEFAULTS['easing']
        s['loop']   = Builders.truthy(raw['loop'])
        s
      end

      # ------------------------------------------------------------------
      # Running
      # ------------------------------------------------------------------

      # Closet Builder units among +entities+, looking two levels into
      # groups and other components (a wall of units is often grouped);
      # kept shallow as it runs on every right-click.
      def self.units_in(entities, depth = 0)
        entities.each_with_object([]) do |e, units|
          if e.is_a?(Sketchup::ComponentInstance) && e.get_attribute(DICT, 'params')
            units << e
          elsif (e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)) && depth < 2
            units.concat(units_in(e.definition.entities, depth + 1))
          end
        end
      end

      def self.running?
        !@player.nil?
      end

      # Animates the doors and drawers of +units+: 'open', 'close' or
      # 'play' (open, pause, close - repeating while the loop setting is
      # on). Returns nil once started, or a message saying why nothing can
      # move. The block is called when the animation ends.
      def self.run(units, action, s = settings, &on_done)
        stop
        units = units.select(&:valid?)
        tracks = units.map(&:definition).uniq.flat_map { |d| tracks(d, s) }
        return no_fronts_message(units) if tracks.empty?
        model = Sketchup.active_model
        @player = Player.new(model, tracks, action, s, on_done)
        model.active_view.animation = @player
        nil
      end

      # Ends the running animation, leaving its parts in their final pose.
      def self.stop
        player = @player
        return unless player
        player.finish
        player.model.active_view.animation = nil if player.model.valid?
      end

      def self.finished(player)
        @player = nil if @player.equal?(player)
      end

      # The moving parts of a unit definition.
      def self.tracks(definition, s)
        found = []
        walk = lambda do |ents, depth|
          ents.grep(Sketchup::ComponentInstance).each do |ci|
            json = ci.get_attribute(DICT, 'motion')
            if json
              found << Track.new(ci, JSON.parse(json), s)
            elsif depth < 2 # bifold leaves sit inside their door
              walk.call(ci.definition.entities, depth + 1)
            end
          end
        end
        walk.call(definition.entities, 0)
        found.select(&:lag).each do |rear|
          found.each { |front| rear.stop_at(front) if front.seq < rear.seq }
        end
        found
      end

      # True when convex XY polygons +a+ and +b+ ([[x, y], ...]) overlap
      # by more than +tol+ (separating axis test).
      def self.overlap?(a, b, tol = 0.01)
        [a, b].all? do |poly|
          poly.each_index.all? do |i|
            (x1, y1), (x2, y2) = poly[i - 1], poly[i]
            nx, ny = y1 - y2, x2 - x1
            len = Math.hypot(nx, ny)
            next true if len < 1e-9
            pa = a.map { |x, y| (x * nx + y * ny) / len }
            pb = b.map { |x, y| (x * nx + y * ny) / len }
            [pa.max, pb.max].min - [pa.min, pb.min].max > tol
          end
        end
      end

      def self.no_fronts_message(units)
        expected = units.any? do |u|
          prm = ClosetBuilder.unit_params(u) || {}
          case prm['type']
          when 'cubby'         then prm['cubby_doors']
          when 'corner_closet' then prm['leg_a_doors'] || prm['leg_b_doors']
          else true
          end
        end
        if expected
          'Units built before animation support need one Update ' \
            '(Edit Closet Unit..., then Update) before they can animate.'
        else
          'No doors or drawers to animate.'
        end
      end

      # One moving part. Its opening value is an angle (radians) for a
      # door or leaf, a distance (inches) for a drawer.
      class Track
        STEP = 0.5.degrees # resolution of stop_at

        attr_reader :inst, :open, :delay, :from, :seq, :lag

        def initialize(inst, m, s)
          @inst  = inst
          @kind  = m['kind']
          @seq   = m['seq'].to_i
          @lag   = m['lag']
          @sign  = m['sign'].to_i
          @pivot = m['pivot'] && Geom::Point3d.new(m['pivot'][0], m['pivot'][1], 0)
          @fold  = m['fold']  && Geom::Point3d.new(m['fold'][0], m['fold'][1], 0)
          @open =
            if @kind == 'slide'
              m['travel'].to_f * s['drawer_extension'] / 100.0
            else
              [s['door_angle'], (m['max'] || 180).to_f].min.degrees
            end
          @delay = [@seq * s['stagger'], @lag.to_f * s['duration']].max
          @from  = current
        end

        # Opens only as far as it can without touching +other+ standing
        # fully open.
        def stop_at(other)
          blocker = other.footprint(other.open)
          angles = (1..(@open / STEP).ceil).map { |i| [i * STEP, @open].min }
          hit = angles.index { |v| Animation.overlap?(footprint(v), blocker) }
          @open = hit.zero? ? 0.0 : angles[hit - 1] if hit
        end

        # XY corners of the part's bounds at opening value +v+.
        def footprint(v)
          b = @inst.definition.bounds
          tr = pose(v)
          [[b.min.x, b.min.y], [b.max.x, b.min.y], [b.max.x, b.max.y], [b.min.x, b.max.y]].map do |x, y|
            pt = tr * Geom::Point3d.new(x, y, 0)
            [pt.x.to_f, pt.y.to_f]
          end
        end

        # Final opening value for +action+ ('play' ends closed).
        def goal(action)
          action == 'open' ? @open : 0.0
        end

        def settled?(action)
          (goal(action) - @from).abs < 1e-6
        end

        # Transformation at opening value +v+.
        def pose(v)
          case @kind
          when 'slide' then Geom::Transformation.translation(Geom::Vector3d.new(0, -v, 0))
          when 'fold'  then turn(@pivot, v) * turn(@fold, -2 * v)
          else              turn(@pivot, v)
          end
        end

        # Opening value of the part's current transformation.
        def current
          tr = @inst.transformation
          return -tr.origin.y.to_f if @kind == 'slide'
          a = Math.atan2(tr.xaxis.y, tr.xaxis.x)
          @kind == 'fold' ? -@sign * a : @sign * a
        end

        private

        def turn(point, v)
          Geom::Transformation.rotation(point, Z_AXIS, @sign * v)
        end
      end

      # SketchUp view animation driving the tracks against the clock.
      class Player
        attr_reader :model

        def initialize(model, tracks, action, s, on_done)
          @model   = model
          @tracks  = tracks
          @action  = action
          @dur     = s['duration']
          @easing  = s['easing']
          @loop    = action == 'play' && s['loop']
          @span    = tracks.map(&:delay).max + @dur # one pass over every part
          @length  = action == 'play' ? 2 * @span + HOLD : @span
          @length  = 0.0 if action != 'play' && tracks.all? { |tr| tr.settled?(action) }
          @on_done = on_done
          @start   = clock
        end

        # SketchUp: show the next frame; false ends the animation.
        def nextFrame(view)
          t = clock - @start
          if @done || (!@loop && t >= @length)
            finish
            return false
          end
          @tracks.each { |tr| tr.inst.move!(tr.pose(value(tr, t))) if tr.inst.valid? }
          view.show_frame
          true
        end

        # SketchUp: stopped by Esc, another tool, or another animation.
        def stop
          finish
        end

        # Rewinds outside the undo stack, then moves every part to its
        # final pose as one undoable operation.
        def finish
          return if @done
          @done = true
          live = @model.valid? ? @tracks.select { |tr| tr.inst.valid? } : []
          if live.any? { |tr| !tr.settled?(@action) }
            live.each { |tr| tr.inst.move!(tr.pose(tr.from)) }
            name = @action == 'open' ? 'Open Doors and Drawers' : 'Close Doors and Drawers'
            @model.start_operation(name, true)
            live.each { |tr| tr.inst.transformation = tr.pose(tr.goal(@action)) }
            @model.commit_operation
          else
            live.each { |tr| tr.inst.move!(tr.pose(tr.from)) }
          end
          @model.active_view.invalidate unless live.empty?
          Animation.finished(self)
          @on_done.call if @on_done
        end

        private

        # Opening value of +tr+ +t+ seconds in. Closing replays the
        # opening schedule backwards: last opened, first closed.
        def value(tr, t)
          close_at = @span - @dur - tr.delay
          case @action
          when 'open'  then ease(tr.from, tr.open, t - tr.delay)
          when 'close' then ease(tr.from, 0.0, t - close_at)
          else
            cycle = 0
            cycle, t = t.divmod(2 * (@span + HOLD)) if @loop
            from = cycle.zero? ? tr.from : 0.0
            if t < @span + HOLD
              ease(from, tr.open, t - tr.delay)
            else
              ease(tr.open, 0.0, t - @span - HOLD - close_at)
            end
          end
        end

        def ease(a, b, t)
          x = [[t / @dur, 0.0].max, 1.0].min
          x =
            case @easing
            when 'linear' then x
            when 'soft'   then 1 - (1 - x)**3 # decelerates like a soft-close damper
            else (1 - Math.cos(Math::PI * x)) / 2
            end
          a + (b - a) * x
        end

        def clock
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
