#Berryton config page : adds a "Berryton AC" page in the Tasmota web Configuration menu
#to edit the settings held in global.berryton_cfg (see Berryton.be). Load it AFTER Berryton.be
#(autoexec.be : load("Berryton.be") then load("berryton_config.be")).

import global
import webserver
import introspect
import string

#field descriptors : [config key, type, label, hint]. type is "bool" (checkbox), "num" (number) or
#"str" (text). hint is an optional wrapping help line shown under the field ("" for none).
var BCFG_FIELDS = [
	["internal_thermostat",          "bool", "Internal thermostat",        "On: ESP regulates (hysteresis). Off: AC regulates on its own sensor + offset"],
	["hyst",                         "num",  "Hysteresis (°C)",            ""],
	["temperature_setpoint_offset",  "num",  "AC-sensor offset (°C)",      "Only used when the internal thermostat is off"],
	["external_temp_mqtt_enabled",   "bool", "Temp. from MQTT",            ""],
	["external_temp_topic",          "str",  "MQTT temperature topic",     ""],
	["external_temp_http_enabled",   "bool", "Temp. from HTTP GET",        ""],
	["external_temp_http_url",       "str",  "HTTP temperature URL",       ""],
	["external_temp_http_interval",  "num",  "HTTP poll interval (s)",     ""],
	["topic_prefix",                 "str",  "MQTT command prefix",        ""],
	["feedback_topic_prefix",        "str",  "MQTT feedback prefix",       ""],
	["ha_discovery_enabled",         "bool", "Publish HA autodiscovery",   ""],
	["ha_full_command_set",          "bool", "Full command set",          "Expose every fan/swing mode (incl. stepless & sweep) instead of the simplified menu"],
	["ha_device_name",               "str",  "HA device name",             ""],
	["ha_unique_id",                 "str",  "HA unique id",               ""],
	["ha_current_temperature_topic", "str",  "HA current-temp topic",      ""],
	["debug",                        "bool", "Debug logging",              ""],
]

class BerrytonConfigPage
	#button in the Configuration menu
	def web_add_config_button()
		webserver.content_send("<p><form action='berryton' method='get'><button>Berryton AC</button></form></p>")
	end

	#register the page handler (called at web server init / boot)
	def web_add_handler()
		webserver.on("/berryton", / -> self.page())
	end

	#read the submitted form into the config object, then persist + republish discovery
	def save_from_form(cfg)
		for f : BCFG_FIELDS
			var key = f[0]
			var typ = f[1]
			if typ == "bool"
				#unchecked checkboxes are not submitted : presence means 1, absence means 0
				introspect.set(cfg, key, webserver.has_arg(key) ? 1 : 0)
			elif webserver.has_arg(key)
				var v = webserver.arg(key)
				introspect.set(cfg, key, typ == "num" ? number(v) : v)
			end
		end
		cfg.save()
		#republish autodiscovery so HA picks up renamed entity / changed menus right away
		if global.contains("berryton_publish_discovery")
			global.berryton_publish_discovery()
		end
	end

	#render one form row for a field given its current value
	def render_field(f, cfg)
		var key = f[0]
		var typ = f[1]
		var label = webserver.html_escape(f[2])
		var hint = (size(f) > 3 && f[3] != "") ? "<br><small style='opacity:0.7'>" + webserver.html_escape(f[3]) + "</small>" : ""
		var val = introspect.get(cfg, key)
		if typ == "bool"
			var checked = (val == 1) ? " checked" : ""
			webserver.content_send(string.format(
				"<p><label><input type='checkbox' name='%s'%s> %s</label>%s</p>", key, checked, label, hint))
		else
			var t = (typ == "num") ? "number" : "text"
			var step = (typ == "num") ? " step='any'" : ""
			webserver.content_send(string.format(
				"<p><b>%s</b>%s<br><input type='%s'%s name='%s' value='%s' style='width:100%%;box-sizing:border-box'></p>",
				label, hint, t, step, key, webserver.html_escape(str(val))))
		end
	end

	#the config page itself (GET shows the form, POST-like save when ?save=1 present)
	def page()
		if !webserver.check_privileged_access() return end
		var cfg = global.berryton_cfg
		if cfg == nil
			webserver.content_start("Berryton AC")
			webserver.content_send_style()
			webserver.content_send("<p>Error : global.berryton_cfg not found. Is Berryton.be loaded ?</p>")
			webserver.content_button(webserver.BUTTON_CONFIGURATION)
			webserver.content_stop()
			return
		end
		var saved = false
		if webserver.has_arg("save")
			self.save_from_form(cfg)
			saved = true
		end
		webserver.content_start("Berryton AC")
		webserver.content_send_style()
		if saved
			webserver.content_send("<p style='color:green'><b>Settings saved.</b> Topic/source changes apply after a Berry restart.</p>")
		end
		#match Tasmota's standard content width (its wrapper is display:inline-block;min-width:340px):
		#fixing our box to 340px keeps the page the same width as every other config page and makes
		#the long hint text wrap instead of growing the inline-block wrapper
		webserver.content_send("<div style='width:340px;max-width:100%;text-align:left;overflow-wrap:break-word'>")
		webserver.content_send("<form action='berryton' method='get'>")
		for f : BCFG_FIELDS
			self.render_field(f, cfg)
		end
		webserver.content_send("<br><button name='save' class='button bgrn' value='1'>Save</button></form></div>")
		webserver.content_button(webserver.BUTTON_CONFIGURATION)   #back to Configuration menu
		webserver.content_stop()
	end
end

global.berryton_config_page = BerrytonConfigPage()
tasmota.add_driver(global.berryton_config_page)
