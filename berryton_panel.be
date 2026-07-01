#Berryton control panel : shows the AC live feedback on the Tasmota main page and adds
#widgets (mode/fan/swing selectors, setpoint slider) to control it. Reads global.berryton_state
#and calls global.berryton_apply (both provided by Berryton.be). Load it AFTER Berryton.be.
#
#The widgets live inside web_sensor() (the auto-refreshed area) and use Tasmota's own ajax :
#  - onmousedown/ontouchstart 'clearTimeout(lt)' freezes the page auto-refresh (global timer lt)
#    while the control is being used, so a select/slider does not jump back mid-interaction ;
#  - onchange 'la("&arg="+value)' submits through Tasmota's ajax (no full reload), which also
#    re-arms the auto-refresh ; the argument is then read at the top of web_sensor() on that call.

import global
import webserver
import string

#control option lists (kept short and practical for the on-device panel)
var BPAN_MODES = ["off","auto","cool","heat","dry","fan_only"]
var BPAN_FANS  = ["auto","low","low-medium","medium","medium-high","high","turbo"]
var BPAN_SWING = ["off","on","high","medium-high","medium","medium-low","low"]

class BerrytonPanel
	#one display row using Tasmota's {s}label{m}value{e} table template
	def row(label, value)
		var v = (value == nil) ? "-" : str(value)
		webserver.content_send("{s}" + label + "{m}" + webserver.html_escape(v) + "{e}")
	end

	#a <select> that submits via ajax la() on change, freezing the auto-refresh while open
	def selector(label, arg, options, current)
		var h = string.format(
			"<p><b>%s</b> <select onmousedown='clearTimeout(lt)' onchange='la(\"&%s=\"+this.value)'>",
			label, arg)
		for o : options
			var sel = (str(current) == o) ? " selected" : ""
			h += "<option value='" + o + "'" + sel + ">" + o + "</option>"
		end
		h += "</select></p>"
		webserver.content_send(h)
	end

	#a config-word toggle in Tasmota relay-button style (green = on, grey = off) ; clicking flips it via ajax la()
	def toggle(label, arg, on)
		var green = (on == 1)
		webserver.content_send(string.format(
			"<p style='margin:4px 0'><button onclick='la(\"&%s=%d\")' style='width:100%%;box-sizing:border-box;" +
			"border:0;border-radius:8px;padding:9px;color:#fff;cursor:pointer;background:%s'>%s : %s</button></p>",
			arg, green ? 0 : 1, green ? "#0a8f2f" : "#666", label, green ? "ON" : "OFF"))
	end

	#called on every main-page ajax refresh : first apply any control argument, then render
	def web_sensor()
		if global.berryton_state == nil return end
		var cfg = global.berryton_cfg

		#1. handle widget submissions (la("&xxx=") lands here as a query arg)
		if global.contains("berryton_apply")
			if webserver.has_arg("bmode") global.berryton_apply("mode", webserver.arg("bmode")) end
			if webserver.has_arg("bfan")  global.berryton_apply("fan",  webserver.arg("bfan"))  end
			if webserver.has_arg("bswg")  global.berryton_apply("swing", webserver.arg("bswg")) end
			if webserver.has_arg("bsp")   global.berryton_apply("temperature", webserver.arg("bsp")) end
		end
		#config-word toggles : route through berryton_set_flag (sets cfg, persists, publishes HA state, re-sends)
		if global.contains("berryton_set_flag")
			if webserver.has_arg("bion") global.berryton_set_flag("ionizer", int(webserver.arg("bion")), true) end
			if webserver.has_arg("bslp") global.berryton_set_flag("sleep",   int(webserver.arg("bslp")), true) end
			if webserver.has_arg("beco") global.berryton_set_flag("eco",     int(webserver.arg("beco")), true) end
			if webserver.has_arg("bdsp") global.berryton_set_flag("display", int(webserver.arg("bdsp")), true) end
		end

		#2. live feedback values
		var s = global.berryton_state
		self.row("AC internal temp °C", s["internal_temp"])
		self.row("Room (external) temp °C", s["external_temp"])

		#3. control widgets
		self.selector("Mode", "bmode", BPAN_MODES, s["mode"])
		self.selector("Fan", "bfan", BPAN_FANS, s["fan"])
		self.selector("Swing", "bswg", BPAN_SWING, s["swing"])
		var sp = (s["setpoint"] == nil) ? 21 : int(real(s["setpoint"]))
		webserver.content_send(string.format(
			"<p><b>Setpoint</b> : <span id='bsplab'>%i</span>°C<br>" +
			"<input type='range' min='16' max='31' step='1' value='%i' " +
			"onmousedown='clearTimeout(lt)' ontouchstart='clearTimeout(lt)' " +
			"oninput=\"clearTimeout(lt);eb('bsplab').innerHTML=this.value\" " +
			"onchange='la(\"&bsp=\"+this.value)' style='width:100%%'>", sp, sp))

		#4. config-word toggles (day-to-day modes, moved here from the config page)
		if cfg != nil
			self.toggle("Ionizer / health", "bion", cfg.ionizer)
			self.toggle("Sleep", "bslp", cfg.sleep)
			self.toggle("Eco", "beco", cfg.eco)
			self.toggle("Display", "bdsp", cfg.display)
		end
	end
end

global.berryton_panel = BerrytonPanel()
tasmota.add_driver(global.berryton_panel)
