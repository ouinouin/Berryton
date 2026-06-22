#Berryton serial emulation : fakes the AC by periodically injecting synthetic A3 feedback frames,
#so the whole receive→parse→display loop can be exercised on a bench ESP32 with no AC attached.
#Enabled by cfg.serial_emulation (default 0). Load it AFTER Berryton.be.
#
#Note: order (command) frames sent to the AC are NOT the same as its feedback frames, and we have
#no order-frame sample, so the emulator does NOT parse commands. Instead it builds a *feedback*
#frame (type A3, format known from a real capture) from the current commanded state held in
#global.berryton_state (kept up to date by the panel's optimistic update), and feeds it through
#global.berryton_feed_frame. The first injected frame also bootstraps the runtime variables in
#Berryton.be (ac_mode, *_setpoint), so the command path stops escaping.

import global
import string

class BerrytonEmul
	#bit/byte layout taken from a real A3 feedback capture (validated byte-for-byte)
	static MODES = ["auto","cool","dry","fan_only","heat"]                 #"off" via the on/off bit
	static FANS  = ["auto","low","low-medium","medium","medium-high","high","stepless","turbo"]
	static SWING = ["off","on","high","medium-high","medium","medium-low","low",
	                "sweep 1-5","sweep 2-5","sweep2-4","sweep1-4","sweep 1-3","sweep 4-6","sweep 3-5"]
	var sim_internal_temp

	def init()
		self.sim_internal_temp = 21.0
		self.schedule()
	end

	def schedule()
		tasmota.set_timer(3000, /-> self.tick(), 3)
	end

	#modbus CRC16 (same as Berryton.be)
	def crc16(data)
		var crc = 0xFFFF
		for i : 0 .. size(data) - 1
			crc = crc ^ data[i]
			for j : 0 .. 7
				if crc & 1   crc = (crc >> 1) ^ 0xA001   else   crc = crc >> 1   end
			end
		end
		return crc
	end

	def idx(lst, v)
		for i : 0 .. size(lst) - 1   if lst[i] == v   return i   end   end
		return 0
	end

	#build an A3 feedback frame from a state, on top of a real-capture template, then append CRC
	def encode(mode, fan, swing, setpoint, temp)
		var f = bytes("7A7AD521220000A30A0A16000029060088000000000164769344423131333730")
		var on = (mode == "off") ? 0 : 1
		var midx = (mode == "off") ? 0 : self.idx(self.MODES, mode)
		f.set(10, int(temp))
		f.set(11, int((temp - int(temp)) * 10 + 0.5))
		f.set(13, midx | (on << 3) | (self.idx(self.FANS, fan) << 4))
		f.set(14, (int(setpoint) - 16) & 0x0F)
		f.set(15, self.idx(self.SWING, swing))
		f.add(self.crc16(f), -2)
		return f
	end

	def tick()
		var cfg = global.berryton_cfg
		if cfg != nil && cfg.serial_emulation == 1 && global.contains("berryton_feed_frame")
			var s = global.berryton_state
			var mode  = (s != nil && s["mode"]     != nil) ? s["mode"]                : "cool"
			var fan   = (s != nil && s["fan"]      != nil) ? s["fan"]                 : "low"
			var swing = (s != nil && s["swing"]    != nil) ? s["swing"]               : "off"
			var sp    = (s != nil && s["setpoint"] != nil) ? int(real(s["setpoint"])) : 21
			#simulate the room slowly reaching the setpoint while the unit is actively conditioning
			if mode != "off" && mode != "fan_only"
				if   self.sim_internal_temp < sp - 0.1   self.sim_internal_temp += 0.2
				elif self.sim_internal_temp > sp + 0.1   self.sim_internal_temp -= 0.2
				end
			end
			global.berryton_feed_frame(self.encode(mode, fan, swing, sp, self.sim_internal_temp))
		end
		self.schedule()   #keep ticking so toggling the setting on/off takes effect live
	end
end

global.berryton_emul = BerrytonEmul()
