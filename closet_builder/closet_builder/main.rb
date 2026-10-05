# Closet Builder - main entry point
require 'json'

module AJL
  module ClosetBuilder
    PLUGIN_DIR = File.dirname(__FILE__) unless defined?(PLUGIN_DIR)
    DICT = 'AJL_ClosetBuilder'

    Sketchup.require File.join(PLUGIN_DIR, 'materials')
    Sketchup.require File.join(PLUGIN_DIR, 'builders')
    Sketchup.require File.join(PLUGIN_DIR, 'animation')
    Sketchup.require File.join(PLUGIN_DIR, 'dialog')

    # Returns the stored params hash for a unit instance, or nil.
    def self.unit_params(instance)
      return nil unless instance.is_a?(Sketchup::ComponentInstance)
      json = instance.get_attribute(DICT, 'params')
      json ? JSON.parse(json) : nil
    rescue JSON::ParserError
      nil
    end

    def self.open_builder_dialog(instance = nil)
      Dialog.show(instance)
    end

    # Animate every unit in the selection (including units inside
    # selected groups) with the saved animation settings.
    def self.animate_selection(action)
      msg = Animation.run(Animation.units_in(Sketchup.active_model.selection), action)
      UI.messagebox(msg) if msg
    end

    unless file_loaded?(__FILE__)
      menu = UI.menu('Extensions').add_submenu('Closet Builder')
      menu.add_item('Build Unit...') { open_builder_dialog }

      UI.add_context_menu_handler do |context_menu|
        sel = Sketchup.active_model.selection
        if sel.size == 1 && unit_params(sel.first)
          context_menu.add_item('Edit Closet Unit...') do
            open_builder_dialog(sel.first)
          end
        end
        if Animation.running?
          context_menu.add_item('Stop Closet Animation') { Animation.stop }
        elsif Animation.units_in(sel).any?
          sub = context_menu.add_submenu('Animate Doors and Drawers')
          sub.add_item('Open')  { animate_selection('open') }
          sub.add_item('Close') { animate_selection('close') }
          sub.add_item('Play')  { animate_selection('play') }
        end
      end

      file_loaded(__FILE__)
    end
  end
end
