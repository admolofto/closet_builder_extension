# Closet Builder - HtmlDialog bridge.

require 'json'

module AJL
  module ClosetBuilder
    module Dialog
      def self.show(instance = nil)
        @dialog.close if @dialog && @dialog.visible? rescue nil

        dlg = UI::HtmlDialog.new(
          dialog_title:    'Closet Builder',
          preferences_key: 'AJL_ClosetBuilder',
          style:           UI::HtmlDialog::STYLE_DIALOG,
          resizable:       true,
          width:           430,
          height:          640
        )
        dlg.set_file(File.join(PLUGIN_DIR, 'ui', 'dialog.html'))

        current = instance # captured; updated after each build

        dlg.add_action_callback('ready') do |_ctx|
          params = current ? ClosetBuilder.unit_params(current) : nil
          rescaled = false
          if params && current && current.valid?
            # If the unit was resized with the Scale tool, fold the scale
            # factors into the stored dimensions so the dialog shows the
            # actual size in the model.
            # Skip for corner units: with two leg lengths and a rotated leg,
            # axis scales don't map onto single width/depth params.
            sx, sy, sz = Builders.scale_factors(current)
            if params['type'] != 'corner_closet' &&
               [sx, sy, sz].any? { |f| (f - 1.0).abs > 0.001 }
              params['width']  = snap(params['width'].to_f  * sx)
              params['depth']  = snap(params['depth'].to_f  * sy)
              params['height'] = snap(params['height'].to_f * sz)
              params['rod_height'] = snap(params['rod_height'].to_f * sz) if params['rod_height']
              rescaled = true
            end
          end
          payload = {
            materials: Materials.options_for_dialog,
            params:    params,
            editing:   !current.nil?,
            rescaled:  rescaled,
            anim:      Animation.settings
          }
          dlg.execute_script("CB.init(#{payload.to_json});")
        end

        dlg.add_action_callback('build') do |_ctx, json|
          begin
            Animation.stop # the rebuild replaces any parts in motion
            params  = JSON.parse(json)
            current = Builders.build(params, current)
            dlg.execute_script('CB.onBuilt(true);')
            Sketchup.active_model.active_view.zoom_extents if params['zoom']
          rescue StandardError => e
            dlg.execute_script("CB.onError(#{e.message.to_json});")
          end
        end

        # Detach: next Build creates a fresh unit instead of updating.
        dlg.add_action_callback('detach') do |_ctx|
          current = nil
          dlg.execute_script('CB.onDetached();')
        end

        # Animation settings are per user, not per unit; Open / Close /
        # Play move the unit being edited.
        dlg.add_action_callback('anim_settings') do |_ctx, json|
          s = Animation.save_settings(JSON.parse(json))
          dlg.execute_script("CB.setAnim(#{s.to_json});")
        end

        dlg.add_action_callback('animate') do |_ctx, action, json|
          s = Animation.save_settings(JSON.parse(json))
          dlg.execute_script("CB.setAnim(#{s.to_json});")
          msg =
            if current && current.valid?
              Animation.run([current], action, s) do
                dlg.execute_script('CB.onAnimDone();') if dlg.visible?
              end
            else
              'Build the unit first.'
            end
          dlg.execute_script(msg ? "CB.onError(#{msg.to_json});" : 'CB.onAnimStart();')
        end

        dlg.add_action_callback('anim_stop') { |_ctx| Animation.stop }

        dlg.add_action_callback('close') { |_ctx| dlg.close }

        dlg.center
        dlg.show
        @dialog = dlg
      end

      # Round to the nearest 1/32" so scaled dimensions stay clean.
      def self.snap(v)
        (v * 32).round / 32.0
      end
    end
  end
end
