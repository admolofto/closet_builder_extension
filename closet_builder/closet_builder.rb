# Closet Builder - SketchUp Extension loader
require 'sketchup.rb'
require 'extensions.rb'

module AJL
  module ClosetBuilder
    unless file_loaded?(__FILE__)
      ex = SketchupExtension.new('Closet Builder', 'closet_builder/main')
      ex.description = 'Parametric closet system: drawer banks, door sections and ' \
                       'cubbies with per-part materials. Right-click a unit to re-edit it ' \
                       'or animate its doors and drawers.'
      ex.version   = '1.2.0'
      ex.copyright = '2026'
      ex.creator   = 'Adam'
      Sketchup.register_extension(ex, true)
      file_loaded(__FILE__)
    end
  end
end
