# Closet Builder - material presets, applied per part role
# (carcass, faces/doors, drawer boxes, backs, shelves).

module AJL
  module ClosetBuilder
    module Materials
      PRESETS = {
        'white_melamine' => { name: 'White Melamine',  color: [246, 246, 242] },
        'grey_melamine'  => { name: 'Grey Melamine',   color: [168, 170, 173] },
        'black_melamine' => { name: 'Black Melamine',  color: [42, 42, 45] },
        'maple'          => { name: 'Maple',           color: [226, 200, 156] },
        'white_oak'      => { name: 'White Oak',       color: [203, 178, 138] },
        'walnut'         => { name: 'Walnut',          color: [96, 67, 47] },
        'birch_ply'      => { name: 'Birch Plywood',   color: [235, 214, 172] },
        'navy'           => { name: 'Navy Lacquer',    color: [44, 58, 86] },
        'sage'           => { name: 'Sage Lacquer',    color: [157, 169, 148] },
        'chrome'         => { name: 'Chrome',          color: [201, 204, 208] }
      }.freeze

      # Find or create the SketchUp material for a preset key.
      def self.fetch(model, key)
        preset = PRESETS[key] || PRESETS['white_melamine']
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
