#Berryton control panel : shows the AC live feedback on the Tasmota main page and adds
#widgets (mode/fan/swing selectors, setpoint slider) to control it. Reads global.berryton_state
#and calls global.berryton_apply (both provided by Berryton.be). Load it AFTER Berryton.be.

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

	#live feedback rows on the main page (this area auto-refreshes every ~2s)
	def web_sensor()
		if global.berryton_state == nil return end
		var s = global.berryton_state
		self.row("Berryton mode", s["mode"])
		self.row("Berryton fan", s["fan"])
		self.row("Berryton swing", s["swing"])
		self.row("Berryton setpoint °C", s["setpoint"])
		self.row("AC internal temp °C", s["internal_temp"])
		self.row("Room (external) temp °C", s["external_temp"])
	end

	#build a <select> that auto-submits on change, current value preselected
	def selector(kind, options, current)
		var h = "<p><form action='berryton_ctl' method='get' style='display:inline'>" + kind +
		        " <select name='" + kind + "' onchange='this.form.submit()'>"
		for o : options
			var sel = (str(current) == o) ? " selected" : ""
			h += "<option value='" + o + "'" + sel + ">" + o + "</option>"
		end
		h += "</select></form></p>"
		webserver.content_send(h)
	end

	#control widgets on the main page (this area is NOT auto-refreshed, so widgets stay usable)
	def web_add_main_button()
		if global.berryton_state == nil return end
		var s = global.berryton_state
		webserver.content_send("<hr><b>Berryton control</b>")
		self.selector("mode", BPAN_MODES, s["mode"])
		self.selector("fan", BPAN_FANS, s["fan"])
		self.selector("swing", BPAN_SWING, s["swing"])
		#setpoint slider 16..31°C, auto-submits when released
		var sp = (s["setpoint"] == nil) ? 21 : int(real(s["setpoint"]))
		webserver.content_send(string.format(
			"<p><form action='berryton_ctl' method='get' style='display:inline'>setpoint " +
			"<output id='bspv'>%d</output>°C<br><input type='range' min='16' max='31' step='1' name='temperature' value='%d' " +
			"style='width:100%%' oninput='bspv.value=this.value' onchange='this.form.submit()'></form></p>", sp, sp))
	end

	#register the control handler (called at boot)
	def web_add_handler()
		webserver.on("/berryton_ctl", / -> self.handle_ctl())
	end

	#apply the received command then bounce back to the main page
	def handle_ctl()
		if !webserver.check_privileged_access() return end
		if global.contains("berryton_apply")
			for kind : ["mode","fan","swing","temperature"]
				if webserver.has_arg(kind)
					global.berryton_apply(kind, webserver.arg(kind))
				end
			end
		end
		webserver.redirect("/")   #back to the main page
	end
end

global.berryton_panel = BerrytonPanel()
tasmota.add_driver(global.berryton_panel)
