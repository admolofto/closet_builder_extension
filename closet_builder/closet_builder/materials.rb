# Closet Builder - material presets, applied per part role
# (carcass, faces/doors, drawer boxes, backs, shelves).

module AJL
  module ClosetBuilder
    module Materials
      PRESETS = {
        'finished_34' => { name: '3/4 finished', color: [235, 214, 172] },
        'rift_34'     => { name: '3/4 rift',     color: [203, 178, 138] },
        'rift_12'     => { name: '1/2 rift',     color: [214, 191, 154] },
        'face_34'     => { name: '3/4 face',     color: [255, 255, 255] },
        'chrome'      => { name: 'Chrome',       color: [201, 204, 208] }
      }.freeze

      # Find or create the SketchUp material for a preset key.
      def self.fetch(model, key)
        preset = PRESETS[key] || PRESETS['finished_34']
        mat_name = "CB #{preset[:name]}"
        mat = model.materials[mat_name]
        unless mat
          mat = model.materials.add(mat_name)
          mat.color = Sketchup::Color.new(*preset[:color])
        end
        mat
      end

      # Resolve the per-role materials hash from dialog params.
      def self.role_materials(model, params)
        {
          carcass: fetch(model, params['mat_carcass']),
          face:    fetch(model, params['mat_face']),
          box:     fetch(model, params['mat_box']),
          back:    fetch(model, params['mat_back']),
          bottom:  fetch(model, params['mat_bottom']),
          shelf:   fetch(model, params['mat_shelf']),
          rod:     fetch(model, 'chrome')
        }
      end

      def self.options_for_dialog
        PRESETS.reject { |k, _| k == 'chrome' }
               .map { |k, v| { key: k, name: v[:name], color: v[:color] } }
      end
    end
  end
end
