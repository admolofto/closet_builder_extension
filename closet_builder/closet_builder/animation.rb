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
# 'seq' orders a unit's fronts (opening order; closing runs it backwards)
# and names them: a bifold door's two leaves share one and move together.
# 'lag' marks a door the doors before it block (the corner closet's rear
# door, lapped by the front one): it opens only as far as they let it,
# after they have moved out of its way, and closes before they close
# past it.
#
# Every request - open, half open or close whole units or single fronts,
# or play - becomes a run. Runs share one view animation, so a door
# clicked while another is moving joins it, and a part asked to move
# again mid-way turns from where it is. Frames move parts with move!,
# outside the undo stack; when a run ends, its parts are rewound and set
# to their final pose in one operation, so Undo returns them to where
# they started.

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
      POSES = { 'open' => 1.0, 'half' => 0.5, 'close' => 0.0 }.freeze # of fully open
      VERBS = { 1.0 => 'Open', 0.5 => 'Half Open', 0.0 => 'Close' }.freeze
      EPS = 1e-3 # opening tolerance (radians or inches)

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
      # Finding units and fronts
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

      # Fronts among +entities+ (doors and drawers selected inside an open
      # unit), as [unit definition, seq] pairs.
      def self.fronts_in(entities)
        entities.grep(Sketchup::ComponentInstance).map { |e| front_of(e) }.compact.uniq
      end

      # [unit definition, seq] of the front +inst+ is (a drawer, door or
      # bifold door) or belongs to (a bifold leaf), or nil.
      def self.front_of(inst)
        m = motion(inst)
        defn = inst.parent
        if m
          unless unit_definition?(defn) # a bifold leaf: its door sits in the unit
            doors = defn.is_a?(Sketchup::ComponentDefinition) ? defn.instances : []
            defn = doors.map(&:parent).find { |d| unit_definition?(d) }
          end
        elsif unit_definition?(defn) # a bifold door: its leaves move
          leaf = inst.definition.entities.grep(Sketchup::ComponentInstance).find { |c| motion(c) }
          m = leaf && motion(leaf)
        end
        m && defn && unit_definition?(defn) ? [defn, m['seq'].to_i] : nil
      end

      def self.unit_definition?(defn)
        defn.is_a?(Sketchup::ComponentDefinition) &&
          defn.instances.any? { |i| i.get_attribute(DICT, 'params') }
      end

      def self.motion(inst)
        json = inst.get_attribute(DICT, 'motion')
        json && JSON.parse(json)
      rescue JSON::ParserError
        nil
      end

      # The front under screen point +x+, +y+ (see Hit), or nil.
      def self.pick(view, x, y)
        hit = view.model.raytest(view.pickray(x, y), true)
        return nil unless hit
        path = hit[1]
        path.each_with_index do |e, i|
          next unless e.is_a?(Sketchup::ComponentInstance) && e.get_attribute(DICT, 'params')
          part = path[i + 1]
          front = part.is_a?(Sketchup::ComponentInstance) && front_of(part)
          return nil unless front && front[0] == e.definition
          return Hit.new(e, front, path[0..i], [part]) if motion(part)
          leaves = part.definition.entities.grep(Sketchup::ComponentInstance).select { |c| motion(c) }
          return Hit.new(e, front, path[0..i + 1], leaves)
        end
        nil
      end

      # The moving parts of a unit definition.
      def self.tracks(definition, s)
        found = []
        walk = lambda do |ents, depth|
          ents.grep(Sketchup::ComponentInstance).each do |ci|
            m = motion(ci)
            if m
              found << Track.new(ci, m, s)
            elsif depth < 2 # bifold leaves sit inside their door
              walk.call(ci.definition.entities, depth + 1)
            end
          end
        end
        walk.call(definition.entities, 0)
        found.select(&:lag).each do |rear|
          rear.blockers = found.select { |front| front.seq < rear.seq }
          rear.blockers.each { |front| rear.stop_at(front) }
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

      # SketchUp reports and takes the transformations of entities inside
      # an open edit context in world coordinates. Returns the
      # transformation from a part's own (unit) coordinates to SketchUp's,
      # or nil while its parent is open with another context active below
      # it (expose closes down to the parent).
      def self.context(inst)
        model = inst.model
        path = model.active_path
        return IDENTITY unless path
        parent = inst.parent
        return model.edit_transform if parent.entities == model.active_entities
        open = path.any? { |e| e.respond_to?(:definition) && e.definition == parent }
        open ? nil : IDENTITY
      end

      # Closes edit contexts opened inside a part's parent (in one of its
      # doors or drawers, say), so SketchUp's coordinates for the part are
      # known.
      def self.expose(tracks)
        return if tracks.empty?
        model = tracks.first.inst.model
        while tracks.any? { |tr| tr.inst.valid? && context(tr.inst).nil? }
          break unless model.close_active
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

      # ------------------------------------------------------------------
      # Running
      # ------------------------------------------------------------------

      def self.running?
        !@player.nil? && !@player.done?
      end

      # Moves the doors and drawers of whole +units+: 'open', 'half',
      # 'close' or 'play' (open, pause, close - repeating while the loop
      # setting is on). Returns nil once started, or a message saying why
      # nothing can move. The block is called when the motion ends.
      def self.run(units, action, s = settings, &on_done)
        units = units.select(&:valid?)
        targets = units.map { |u| [u.definition, nil] }.to_h
        start(targets, action, s, on_done) ? nil : no_fronts_message(units)
      end

      # Moves single fronts ([unit definition, seq] pairs, from fronts_in
      # or pick): 'open', 'half', 'close', 'toggle' (open, or close if
      # open) or 'toggle_half' (half open, or close if half open). Returns
      # nil once started, or a message. The block is called when done.
      def self.run_fronts(fronts, action, s = settings, &on_done)
        targets = {}
        fronts.each { |defn, seq| (targets[defn] ||= []) << seq if defn.valid? }
        start(targets, action, s, on_done) ? nil : 'No doors or drawers to animate.'
      end

      # Ends all motion, leaving parts in their final pose.
      def self.stop
        player = @player
        return unless player
        player.finish
        player.model.active_view.animation = nil if @player.nil? && player.model.valid?
      end

      def self.finished(player)
        @player = nil if @player.equal?(player)
      end

      # Selects the tool that opens and closes fronts one click at a time.
      def self.pick_fronts
        Sketchup.active_model.select_tool(PickTool.new)
      end

      def self.clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def self.ease(a, b, x, easing)
        x = [[x, 0.0].max, 1.0].min
        x =
          case easing
          when 'linear' then x
          when 'soft'   then 1 - (1 - x)**3 # decelerates like a soft-close damper
          else (1 - Math.cos(Math::PI * x)) / 2
          end
        a + (b - a) * x
      end

      # Starts a run moving +targets+ ({unit definition => seqs, nil
      # meaning every front}); false when they have nothing to move.
      def self.start(targets, action, s, on_done)
        stop if action == 'play' || (running? && @player.playing?)
        model = Sketchup.active_model
        stop if running? && @player.model != model
        units = targets.keys.select(&:valid?).map { |d| [d, tracks(d, s)] }
        all = units.flat_map(&:last)
        return false if all.empty?
        expose(all)
        now = clock
        motions = []
        frac = nil
        if action == 'play'
          motions = play(all, s, now)
          frac = 0.0 # play ends closed
        else
          units.each do |defn, trs|
            goals, delays, f = plan(trs, targets[defn], action, s, now)
            frac ||= f
            goals.each { |tr, g| motions << Motion.new(tr, g, now + delays[tr], s) }
          end
        end
        seqs = targets.values
        what =
          if seqs.size == 1 && seqs.first && seqs.first.size == 1
            all.any? { |tr| tr.seq == seqs.first.first && tr.kind == 'slide' } ? 'Drawer' : 'Door'
          else
            'Doors and Drawers'
          end
        run = Run.new("#{VERBS[frac || 0.0]} #{what}", action == 'play', on_done)
        fresh = !running?
        @player = Player.new(model) if fresh
        @player.add(run, motions)
        model.active_view.animation = @player if fresh
        true
      end

      # Goals and start delays for moving the fronts +seqs+ (nil: every
      # front, staggered) of one unit's tracks +trs+, and the first
      # front's opening fraction. Parts already heading for their goal
      # keep going in their own run. Interlocked doors stay clear of each
      # other: a rear door opens only as far as the door in front of it
      # allows (opening that door first if it is in the way), and closes
      # before that door closes past it.
      def self.plan(trs, seqs, action, s, now)
        moving = ->(tr) { @player && @player.motion(tr.inst) }
        target = ->(tr) { (mo = moving.call(tr)) ? mo.goal : tr.live }
        goals = {}
        frac = nil
        picked = seqs ? trs.select { |tr| seqs.include?(tr.seq) } : trs
        picked.group_by(&:seq).each_value do |front|
          f = fraction(action, front.first, target)
          frac ||= f
          front.each { |tr| goals[tr] = f * tr.open }
        end
        trs.select(&:lag).each do |rear|
          rear.blockers.each do |front|
            if goals.key?(rear) && !goals.key?(front) &&
               goals[rear] > rear.limit(front, target.call(front)) + EPS
              goals[front] = front.open
            end
            room = rear.limit(front, goals.fetch(front) { target.call(front) })
            if goals.key?(rear)
              goals[rear] = [goals[rear], room].min
            elsif goals.key?(front) && target.call(rear) > room + EPS
              goals[rear] = room
            end
          end
        end
        goals.reject! { |tr, g| (mo = moving.call(tr)) && (mo.goal - g).abs < EPS }

        top = trs.map(&:seq).max
        delays = {}
        goals.each do |tr, g|
          delays[tr] = seqs ? 0.0 : (g >= tr.live ? tr.seq : top - tr.seq) * s['stagger']
        end
        heading = ->(tr) { goals.key?(tr) ? goals[tr] : (mo = moving.call(tr)) && mo.goal }
        opens  = ->(tr) { (g = heading.call(tr)) && g > tr.live + EPS }
        closes = ->(tr) { (g = heading.call(tr)) && g < tr.live - EPS }
        ends   = ->(tr) { goals.key?(tr) ? delays[tr] + s['duration'] : moving.call(tr).finish - now }
        trs.select(&:lag).each do |rear|
          rear.blockers.each do |front|
            if goals.key?(rear) && opens.call(rear) && opens.call(front)
              delays[rear] = [delays[rear], ends.call(front)].max
            elsif goals.key?(front) && closes.call(front) && closes.call(rear)
              delays[front] = [delays[front], ends.call(rear)].max
            end
          end
        end
        [goals, delays, frac]
      end

      # Opening fraction +action+ asks of the front led by track +tr+,
      # whose current target opening +target+ gives.
      def self.fraction(action, tr, target)
        case action
        when 'toggle'      then target.call(tr) > EPS ? 0.0 : 1.0
        when 'toggle_half' then (target.call(tr) - tr.open / 2).abs < EPS ? 0.0 : 0.5
        else POSES.fetch(action)
        end
      end

      # Play: parts open in sequence, pause, and close in reverse.
      def self.play(trs, s, now)
        dur = s['duration']
        delays = trs.map { |tr| [tr, [tr.seq * s['stagger'], tr.lag.to_f * dur].max] }.to_h
        span = delays.values.max + dur # one pass over every part
        trs.map { |tr| PlayMotion.new(tr, now, s, delays[tr], span) }
      end

      # One moving part. Its opening is an angle (radians) for a door or
      # leaf, a distance (inches) for a drawer.
      class Track
        STEP = 0.5.degrees # resolution of limit

        attr_reader :inst, :kind, :seq, :lag, :open
        attr_accessor :blockers

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
          @blockers = []
        end

        # Largest opening, up to fully open, the part reaches from closed
        # without touching +other+ standing at opening +v+.
        def limit(other, v)
          blocker = other.footprint(v)
          steps = (1..(@open / STEP).ceil).map { |i| [i * STEP, @open].min }
          hit = steps.index { |a| Animation.overlap?(footprint(a), blocker) }
          return @open unless hit
          hit.zero? ? 0.0 : steps[hit - 1]
        end

        # Opens only as far as +other+ standing fully open allows.
        def stop_at(other)
          @open = limit(other, other.open)
        end

        # XY corners of the part's bounds at opening +v+.
        def footprint(v)
          b = @inst.definition.bounds
          tr = pose(v)
          [[b.min.x, b.min.y], [b.max.x, b.min.y], [b.max.x, b.max.y], [b.min.x, b.max.y]].map do |x, y|
            pt = tr * Geom::Point3d.new(x, y, 0)
            [pt.x.to_f, pt.y.to_f]
          end
        end

        # Transformation at opening +v+.
        def pose(v)
          case @kind
          when 'slide' then Geom::Transformation.translation(Geom::Vector3d.new(0, -v, 0))
          when 'fold'  then turn(@pivot, v) * turn(@fold, -2 * v)
          else              turn(@pivot, v)
          end
        end

        # Opening of the part's transformation when first asked.
        def live
          @live ||= begin
            tr = (Animation.context(@inst) || IDENTITY).inverse * @inst.transformation
            if @kind == 'slide'
              -tr.origin.y.to_f
            else
              a = Math.atan2(tr.xaxis.y, tr.xaxis.x)
              @kind == 'fold' ? -@sign * a : @sign * a
            end
          end
        end

        # Moves the part to opening +v+, outside the undo stack.
        def place(v)
          ctx = Animation.context(@inst)
          @inst.move!(ctx * pose(v)) if ctx
        end

        # Sets opening +v+, inside an operation.
        def set(v)
          @inst.transformation = (Animation.context(@inst) || IDENTITY) * pose(v)
        end

        private

        def turn(point, v)
          Geom::Transformation.rotation(point, Z_AXIS, @sign * v)
        end
      end

      # A part easing from where it is to +goal+, starting at +start+.
      class Motion
        attr_reader :track, :goal, :finish
        attr_accessor :rest, :run

        def initialize(track, goal, start, s)
          @track   = track
          @from    = track.live
          @rest    = @from # Undo's pose; kept when another run takes over
          @goal    = goal
          @start   = start
          @dur     = s['duration']
          @easing  = s['easing']
          @finish  = start + @dur
          @settled = (goal - @from).abs < EPS
        end

        def value(t)
          Animation.ease(@from, @goal, (t - @start) / @dur, @easing)
        end

        def done?(t)
          @settled || t >= @finish
        end
      end

      # Play's motion: open after +delay+, pause, close in reverse order
      # (and again, while looping).
      class PlayMotion < Motion
        def initialize(track, start, s, delay, span)
          super(track, 0.0, start, s)
          @delay    = delay
          @span     = span
          @close_at = span - @dur - delay # last opened, first closed
          @loop     = s['loop']
        end

        def value(t)
          t -= @start
          cycle = 0
          cycle, t = t.divmod(2 * (@span + HOLD)) if @loop
          from = cycle.zero? ? @from : 0.0
          if t < @span + HOLD
            Animation.ease(from, @track.open, (t - @delay) / @dur, @easing)
          else
            Animation.ease(@track.open, 0.0, (t - @span - HOLD - @close_at) / @dur, @easing)
          end
        end

        def done?(t)
          !@loop && t - @start >= 2 * @span + HOLD
        end
      end

      # The parts one request moves; they land as one undoable operation.
      class Run
        attr_reader :name, :motions, :on_done

        def initialize(name, exclusive, on_done)
          @name      = name
          @exclusive = exclusive # play runs alone
          @on_done   = on_done
          @motions   = []
        end

        def exclusive?
          @exclusive
        end
      end

      # SketchUp view animation driving every run's parts against the clock.
      class Player
        attr_reader :model

        def initialize(model)
          @model   = model
          @runs    = []
          @motions = {} # part => the Motion driving it
        end

        def done?
          @done
        end

        def playing?
          @runs.any?(&:exclusive?)
        end

        def motion(inst)
          @motions[inst]
        end

        # Adds +run+, taking its parts over from earlier runs.
        def add(run, motions)
          motions.each do |mo|
            old = @motions[mo.track.inst]
            if old
              old.run.motions.delete(old)
              mo.rest = old.rest
            end
            mo.run = run
            run.motions << mo
            @motions[mo.track.inst] = mo
          end
          @runs << run
        end

        # SketchUp: show the next frame; false ends the animation.
        def nextFrame(view)
          return false if @done
          t = Animation.clock
          @motions.each_value { |mo| mo.track.place(mo.value(t)) if mo.track.inst.valid? }
          @runs.select { |r| r.motions.all? { |mo| mo.done?(t) } }.each { |r| land(r) }
          return false if @done
          view.show_frame
          return true unless @runs.empty?
          finish
          false
        end

        # SketchUp: replaced by another animation, or cleared.
        def stop
          finish
        end

        # Ends every run, leaving its parts at their goals.
        def finish
          return if @done
          @done = true
          Animation.finished(self)
          @runs.dup.each { |r| land(r) }
        end

        private

        # Rewinds the run's parts outside the undo stack, then moves them
        # to their goals as one undoable operation.
        def land(run)
          @runs.delete(run)
          run.motions.each { |mo| @motions.delete(mo.track.inst) }
          live = @model.valid? ? run.motions.select { |mo| mo.track.inst.valid? } : []
          unless live.empty?
            Animation.expose(live.map(&:track))
            live.each { |mo| mo.track.place(mo.rest) }
            moved = live.reject { |mo| (mo.goal - mo.rest).abs < EPS }
            unless moved.empty?
              @model.start_operation(run.name, true)
              moved.each { |mo| mo.track.set(mo.goal) }
              @model.commit_operation
            end
            @model.active_view.invalidate
          end
          run.on_done.call if run.on_done
        end
      end

      # A front under the cursor: its +unit+ instance, +front+ ([unit
      # definition, seq]) and moving +parts+, whose parent the instance
      # path +parent_path+ leads to.
      class Hit
        BOX = (0..7).flat_map { |i| [1, 2, 4].map { |b| [i, i | b] } }.reject { |i, j| i == j }

        attr_reader :unit, :front, :label

        def initialize(unit, front, parent_path, parts)
          @unit        = unit
          @front       = front
          @parent_path = parent_path
          @parts       = parts
          @label = parts.any? { |p| Animation.motion(p)['kind'] == 'slide' } ? 'Drawer' : 'Door'
        end

        def key
          [@unit, @front[1]]
        end

        def valid?
          (@parent_path + @parts).all?(&:valid?)
        end

        # Screen-space edges of the parts' bounding boxes as they stand.
        # SketchUp reports the instances along a path from the model root
        # so their product is the world transformation, even in an open
        # edit context.
        def edges(view)
          base = @parent_path.inject(Geom::Transformation.new) { |t, e| t * e.transformation }
          @parts.flat_map do |part|
            tr = base * part.transformation
            b = part.definition.bounds
            pts = (0..7).map { |n| view.screen_coords(tr * b.corner(n)) }
            BOX.flat_map { |i, j| [pts[i], pts[j]] }
          end
        end
      end

      # Tool: click doors and drawers to open or close them one at a time.
      class PickTool
        STATUS = 'Click a door or drawer to open or close it, Shift+click to half ' \
                 'open it. Right-click for more. Esc when done.'.freeze
        COLOR = Sketchup::Color.new(15, 118, 110)

        def activate
          @hit = nil
          Sketchup.status_text = STATUS
        end

        def deactivate(view)
          view.invalidate
        end

        def resume(view)
          Sketchup.status_text = STATUS
          view.invalidate
        end

        def onMouseMove(_flags, x, y, view)
          hit = Animation.pick(view, x, y)
          if (hit && hit.key) != (@hit && @hit.key)
            view.tooltip = hit ? hit.label : ''
            view.invalidate
          end
          @hit = hit
          Sketchup.status_text = STATUS
        end

        def onMouseLeave(view)
          @hit = nil
          view.invalidate
        end

        def onLButtonDown(flags, x, y, view)
          hit = Animation.pick(view, x, y)
          return unless hit
          half = (flags & CONSTRAIN_MODIFIER_MASK) != 0
          report(Animation.run_fronts([hit.front], half ? 'toggle_half' : 'toggle'))
        end

        def getMenu(menu, _flags, x, y, view)
          hit = Animation.pick(view, x, y)
          if hit
            POSES.each do |action, frac|
              menu.add_item("#{VERBS[frac]} #{hit.label}") do
                report(Animation.run_fronts([hit.front], action))
              end
            end
            menu.add_separator
            POSES.each do |action, frac|
              menu.add_item("#{VERBS[frac]} All") { report(Animation.run([hit.unit], action)) }
            end
            menu.add_item('Play') { report(Animation.run([hit.unit], 'play')) }
            menu.add_separator
          end
          menu.add_item('Done') { Sketchup.active_model.select_tool(nil) }
        end

        # Esc stops the motion, or ends the tool when nothing moves.
        def onCancel(reason, _view)
          return unless reason.zero?
          if Animation.running?
            Animation.stop
          else
            Sketchup.active_model.select_tool(nil)
          end
        end

        def draw(view)
          return unless @hit && @hit.valid?
          view.line_width = 2
          view.line_stipple = ''
          view.drawing_color = COLOR
          view.draw2d(GL_LINES, @hit.edges(view))
        end

        private

        def report(msg)
          UI.messagebox(msg) if msg
        end
      end
    end
  end
end
