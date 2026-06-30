#airton protocol from me and brice (pingus.org). Design notes, frame layout, TODOs : see NOTES.md

import string
import mqtt
import persist
import introspect
import json
import global

# --- all tunable settings live here, persisted to flash and editable from the config page ---
class BerrytonConfig
	var debug
	var topic_prefix, feedback_topic_prefix
	#per-mode regulation (heat / cool) : how the room is regulated and where the room temperature comes from.
	#  *_source : "ac"   = the AC regulates on its own sensor (we just apply *_offset to the setpoint we send)
	#             "mqtt" = the ESP regulates (hysteresis on *_hyst) using the room temp read from *_temp_topic
	#             "http" = same, room temp polled from *_http_url every *_http_interval seconds
	var heat_source, heat_offset, heat_hyst, heat_temp_topic, heat_http_url, heat_http_interval
	var cool_source, cool_offset, cool_hyst, cool_temp_topic, cool_http_url, cool_http_interval
	var ha_discovery_enabled, ha_full_command_set, ha_device_name, ha_unique_id
	var ha_current_temp_source                        #temp reported to HA : "ac_sensor" or "regulation"
	var serial_emulation, beep
	var display, ionizer, sleep, eco                  #AC config-word flags (emission byte 15)
	#list of the persisted settings (stored in flash under "cfg_<name>")
	static keys = ["debug","topic_prefix","feedback_topic_prefix",
	               "heat_source","heat_offset","heat_hyst","heat_temp_topic","heat_http_url","heat_http_interval",
	               "cool_source","cool_offset","cool_hyst","cool_temp_topic","cool_http_url","cool_http_interval",
	               "ha_discovery_enabled","ha_full_command_set","ha_device_name","ha_unique_id",
	               "ha_current_temp_source","serial_emulation","beep",
	               "display","ionizer","sleep","eco"]
	#settings persisted by an older version, now replaced by the per-mode model : removed from flash on boot
	static obsolete_keys = ["internal_thermostat","temperature_setpoint_offset","hyst",
	                        "external_temp_mqtt_enabled","external_temp_topic",
	                        "external_temp_http_enabled","external_temp_http_url","external_temp_http_interval",
	                        "ha_current_temperature_topic"]

	def init()
		#defaults used on first boot, before anything has been saved to flash
		self.debug = 1
		self.topic_prefix = "cmnd/Newclim/"
		self.feedback_topic_prefix = "tele/Newclim/"
		#per-mode regulation : clean defaults = let the AC regulate on its own sensor, no offset, no external temp
		self.heat_source = "ac"                           #"ac" | "mqtt" | "http"
		self.heat_offset = 0                              #°C added to the setpoint sent to the AC (compensates a high-placed sensor)
		self.heat_hyst = 0.3                              #hysteresis (°C) when the ESP regulates
		self.heat_temp_topic = ""                         #MQTT topic carrying the room temperature
		self.heat_http_url = ""                           #e.g. http://192.168.0.10/temp (body should contain a number)
		self.heat_http_interval = 60                      #seconds between HTTP polls
		self.cool_source = "ac"
		self.cool_offset = 0
		self.cool_hyst = 0.3
		self.cool_temp_topic = ""
		self.cool_http_url = ""
		self.cool_http_interval = 60
		self.ha_discovery_enabled = 1
		self.ha_full_command_set = 0
		self.ha_device_name = "Airton"
		self.ha_unique_id = "berryton_newclim"
		self.ha_current_temp_source = "ac_sensor"         #"ac_sensor" = AC's own sensor ; "regulation" = the room temp used for regulation
		self.serial_emulation = 0                         #1=fake AC feedback frames for bench testing (no real unit)
		self.beep = 1                                     #1=AC beeps on each command (default), 0=silent (byte 16 = 0x01)
		#config-word flags (emission byte 15) ; defaults keep the historical 0x98 value
		self.display = 1                                  #1=LCD/display on (bit 0x80)
		self.ionizer = 0                                  #1=ionizer/health on (bit 0x40)
		self.sleep = 0                                    #1=sleep mode (bit 0x02)
		self.eco = 0                                      #1=eco mode (bit 0x01)
		self.load()
		self.cleanup_obsolete()
	end

	#drop obsolete cfg_* entries left in flash by an older version (one-off ; only writes when something changed)
	def cleanup_obsolete()
		var changed = false
		for k : self.obsolete_keys
			var pk = "cfg_" + k
			if persist.has(pk)
				persist.remove(pk)
				changed = true
			end
		end
		if changed
			persist.save()
		end
	end

	#load each setting from flash, keeping the default when nothing has been saved yet
	def load()
		for k : self.keys
			var v = introspect.get(persist, "cfg_" + k)
			if v != nil
				introspect.set(self, k, v)
			end
		end
	end

	#persist every setting to flash
	def save()
		for k : self.keys
			introspect.set(persist, "cfg_" + k, introspect.get(self, k))
		end
		persist.save()
	end
end

global.berryton_cfg = BerrytonConfig()
var cfg = global.berryton_cfg

#latest known values, exposed for the web UI control panel (see berryton_panel.be)
global.berryton_state = {"internal_temp":nil, "external_temp":nil, "mode":nil, "fan":nil, "swing":nil, "setpoint":nil, "remote":nil}

#runtime state (not user settings ; the tunable settings live in the BerrytonConfig object 'cfg' below)
var fan_speed_setpoint
var oscillation_mode_setpoint
var temperature_setpoint
var ac_mode
var temperature_setpoint_to_ac_unit
var external_temp_value = 19 							# set to a value in case the temperature update from an external sensor is long.
var remote_control_state                                # last IR-remote state seen in a frame A4 : "on"/"off"/"unknown"

# regulation vocabulary & design (per-mode model, user-setpoint invariant, offset) : see NOTES.md
# --- per-mode regulation accessors : resolve the heat_/cool_ config key for the given AC mode ---
# any mode other than heat/cool (auto/dry/fan_only/off) has no ESP regulation : treated as source "ac".
var EXT_TEMP_HTTP = "__berryton_http_temp__"        #sentinel "topic" used to feed an HTTP reading into the dispatcher
def reg_get(mode, suffix, dflt)
	if mode != "heat" && mode != "cool" return dflt end
	var v = introspect.get(cfg, mode + "_" + suffix)
	return v != nil ? v : dflt
end
def reg_source(mode)        return reg_get(mode, "source", "ac") end
def reg_offset(mode)        return reg_get(mode, "offset", 0) end
def reg_hyst(mode)          return reg_get(mode, "hyst", 0.3) end
def reg_topic(mode)         return reg_get(mode, "temp_topic", "") end
def reg_http_url(mode)      return reg_get(mode, "http_url", "") end
def reg_http_interval(mode) return reg_get(mode, "http_interval", 60) end
#true when the incoming MQTT topic is a room-temperature topic for one of the (mqtt-source) modes
def is_ext_topic(topic)
	if topic == EXT_TEMP_HTTP return true end
	for m : ["heat", "cool"]
		if reg_source(m) == "mqtt" && topic == reg_topic(m) return true end
	end
	return false
end

# serial communications (pin 26 TX , PIN 32 RX)
ser = serial(32, 26, 9600, serial.SERIAL_8N1)

#debug print helper : prints only when debug is enabled, so there is no need for an "if debug" around every call
def dprint(*args)
	if !cfg.debug return end
	var line = ""
	for a : args
		line += str(a)
	end
	print(line)
end

#an internal simple thermostat  returns 0 while the unit should stop and 1 while it should start
var last_thermostat_state
def thermostat(setpoint,actual_temp)
	var delta
	if ac_mode == "heat"
		delta = actual_temp - setpoint
	elif ac_mode == "cool"
		delta = setpoint - actual_temp
	else
		delta = 0.0
	end
	dprint("function thermostat : setpoint=", setpoint , " delta=", delta," last_thermostat_state=",last_thermostat_state)
	if (delta > reg_hyst(ac_mode) ) && last_thermostat_state!= 0
		dprint("function thermostat : delta > hyst")
		last_thermostat_state = 0
		dprint("function thermostat : last_thermostat_state=",last_thermostat_state)
		return 0

	elif (delta < -reg_hyst(ac_mode) ) && last_thermostat_state!= 1
		dprint("function thermostat  : delta < -hyst ")
		last_thermostat_state = 1
		dprint("function thermostat : last_thermostat_state=",last_thermostat_state)
		return 1

	end

end
# used to write to flash only if values differs , storageplace is a string
def store_if_different(value_to_compare,storage_place)
	if number(introspect.get(persist, storage_place)) == value_to_compare
		dprint("function store_if_different : nothing to store")
		return
	else
		introspect.set(persist, storage_place,value_to_compare)
		dprint("function store_if_different : storing the value :",value_to_compare, "to persist.",storage_place)
	end
end

#modbus CRC16
def mod_crc16(data, poly)
	if !poly  poly = 0xA001 end
	# CRC-16 MODBUS HASHING ALGORITHM
	var crc = 0xFFFF
	for i:0..size(data)-1
		crc = crc ^ data[i]
		for j:0..7
			if crc & 1
				crc = (crc >> 1) ^ poly
			else
				crc = crc >> 1
			end
		end
	end
	return crc
end

#checking messages incoming from AC unit CRCet
def check_message(payload)
	var msg_cal_crc = mod_crc16(payload[0..payload.size()-3])
	var msg_crc = payload.get(payload.size()-2,-2) # last -2 param means endianness swap
	if msg_cal_crc == msg_crc
		return 1
	else
		return 0
	end
end






#retrieve the AC unit mode from the AC unit frame
def get_ac_mode(payload) # available modes are : "auto","cool","dry","fan_only","heat"
	var ac_mode_list = ["auto","cool","dry","fan_only","heat","off",]
	var ac_mode_string = "auto"
	var ac_on_off_state = 0
	ac_on_off_state = payload.getbits(107,1)
	if ac_on_off_state == 1
		var mode_idx = payload.getbits(104,3)          #3 bits give 0..7 but the list has only 6 entries
		if mode_idx < ac_mode_list.size()
			ac_mode_string = ac_mode_list[mode_idx]
		end                                            #out of range : keep the "auto" default
	else
		ac_mode_string = ac_mode_list[5]
	end
	dprint("function get_ac_mode :  ac_mode_string = " , ac_mode_string ) #debug
	return ac_mode_string
end

#retrieve the AC fan speed from the AC unit frame
def get_fan_speed(payload)
	var turbo_mode_state = 0
	var fan_mode_string = "auto"
	var fan_mode_list = ["auto","low","low-medium","medium","medium-high","high","stepless","turbo"]
	if turbo_mode_state == 0
		fan_mode_string = fan_mode_list[payload.getbits(108,3)]
	else
		fan_mode_string = fan_mode_list[7]
	end
	dprint( "function get_fan_speed : fan_mode_string = " , fan_mode_string)
	return fan_mode_string
end

#retrieve the AC oscillation mode from the AC unit frame
def get_oscillation_mode(payload)
	var oscillation_mode_list = ["off", "on" ,"high","medium-high","medium","medium-low","low","sweep 1-5","sweep 2-5","sweep2-4","sweep1-4","sweep 1-3","sweep 4-6","sweep 3-5"]
	var osc_idx = payload.getbits(120,4)               #4 bits give 0..15 but the list has only 14 entries
	var oscillation_mode_string = "off"                #default if the value exceeds the list
	if osc_idx < oscillation_mode_list.size()
		oscillation_mode_string = oscillation_mode_list[osc_idx]
	end
	dprint("function get_oscillation_mode : oscillation_mode_string = ", oscillation_mode_string)
	return oscillation_mode_string
end

#retrieve the AC internal unit temperature sensor value from the AC unit frame
def get_internal_temperature(payload)
	var temperature = 0
	temperature = real(payload.get(10,1)) + real(payload.get(11,1)) /10
	dprint("function get_internal_temperature : internal unit temperature: ", temperature)
	return temperature
end

def publish_feedback(payload)
	var my_ac_mode = get_ac_mode(payload)
	var my_fan_speed = get_fan_speed(payload)
	var my_oscillation_mode = get_oscillation_mode(payload)

	# temperature_setpoint is the user's target (set by temperature/set, persisted as TempSetpoint) ; we report
	# it verbatim and never derive it from the AC frame here : the frame carries the offsetted / hysteresis value,
	# not the user target. (Reading the frame back is the infrared-remote sync, deferred to a later phase.)
	var my_temperature = str(get_internal_temperature(payload) )
	#initialize settings value with first feedback from AC unit to manage restart conditions
	if fan_speed_setpoint == nil fan_speed_setpoint = my_fan_speed  dprint("recovered fan_speed_setpoint : " , fan_speed_setpoint) end
	if oscillation_mode_setpoint == nil oscillation_mode_setpoint = my_oscillation_mode dprint("recovered oscillation_mode_setpoint : ", oscillation_mode_setpoint) end
	if temperature_setpoint == nil dprint("no temperature_setpoint available, check persistance file value :", temperature_setpoint) end
	if ac_mode == nil ac_mode = my_ac_mode dprint("recovered ac_mode : ", ac_mode) end


	#update the live state for the web UI panel
	global.berryton_state["internal_temp"] = my_temperature
	global.berryton_state["mode"] = my_ac_mode
	global.berryton_state["fan"] = my_fan_speed
	global.berryton_state["swing"] = my_oscillation_mode
	global.berryton_state["setpoint"] = temperature_setpoint

	dprint("function publish_feedback : got all needed value, publishing in mqtt topics")
	mqtt.publish(cfg.feedback_topic_prefix + "mode/get" , my_ac_mode)
	mqtt.publish(cfg.feedback_topic_prefix + "fan/get" , my_fan_speed)
	mqtt.publish(cfg.feedback_topic_prefix + "swing/get" , my_oscillation_mode)
	#current temperature reported to HA : the AC's own sensor, or the room temp used for regulation (config choice)
	var ha_temp = (cfg.ha_current_temp_source == "regulation") ? str(external_temp_value) : my_temperature
	mqtt.publish(cfg.feedback_topic_prefix + "Actualtemp/get" , ha_temp)
	mqtt.publish(cfg.feedback_topic_prefix + "Actualsetpoint/get" , str(temperature_setpoint))

end

#frame A4 (AC->ESP) : the AC reports an IR-remote state change. byte 10 carries the state.
#0x00 = remote ON, 0x01 = remote OFF, 0xA5 = unknown (see UnleashedAirConditionner, frame A4).
#read-only for now : we log it, expose it and publish it, to later align with the IR remote.
def decode_remote_control(payload)
	var data = payload[10]
	var s = (data == 0x00) ? "on" : ((data == 0x01) ? "off" : "unknown")
	remote_control_state = s
	global.berryton_state["remote"] = s
	dprint("function decode_remote_control : frame A4 : IR remote = ", s, " (byte10=0x", string.hex(data), ") raw: ", payload.tostring(60))
	mqtt.publish(cfg.feedback_topic_prefix + "remote/get", s)
end

def get_frame_type(payload)
	if check_message(payload) != 1
		return "BADCRC"
	end
	var ftype = string.hex(payload[7])      #frame type byte
	if ftype == "A3" && payload.size() == 34
		#feedback frame : the AC's full state
		dprint("function get_frame_type : valid message from AC unit :", payload.tostring(60))
		publish_feedback(payload)
		return "ACFeedback"
	elif ftype == "A4"
		#IR-remote state change
		decode_remote_control(payload)
		return "RemoteControl"
	else
		dprint("function get_frame_type : unhandled frame type 0x", ftype, " (", payload.size(), " bytes) : ", payload.tostring(60))
		return "UNHANDLED"
	end
end


def forge_payload(ac_mode,fan_speed,oscillation_mode,temperature_sp)
	var frame = bytes("7A7A21D5180000A100000000" + "00000000" + "000000000000")
	var ac_mode_values = {"auto": 0x00 , "cool" : 0x01 , "dry" : 0x02 , "fan_only" : 0x03 , "heat": 0x04 , "off" : 0x08}
	var fan_mode_values = {"auto" : 0x00 ,"low" : 0x10 , "low-medium" : 0x20 ,"medium" : 0x30 , "medium-high" : 0x40 , "high" : 0x50 ,"stepless" : 0x60  ,"turbo" : 0x70 }
	var oscillation_mode_values = {"off" : 0x00 , "on" : 0x01 ,"high" : 0x02 ,"medium-high" : 0x03 ,"medium" : 0x04 ,"medium-low" : 0x05 ,"low" : 0x06 ,"sweep 1-5" : 0x07 ,"sweep 2-5" : 0x08 ,"sweep2-4" : 0x09 ,"sweep1-4" : 0x0A ,"sweep 1-3" : 0x0B ,"sweep 4-6" : 0x0C ,"sweep 3-5": 0X0D}

	#setting ac_mode on register 12 of the frame
	var reg12 = 0x00
	var reg13 = 0x00
	var reg14 = 0x00
	#config word (byte 15) : bit7 display, bit6 ionizer, bit4 aux heater, bits3-2 display mode, bit1 sleep, bit0 eco
	#base 0x18 preserves the historical aux-heater + display-mode bits ; user flags are OR-ed in (defaults -> 0x98)
	var reg15 = 0x18
	if cfg.display == 1 reg15 = reg15 | 0x80 end
	if cfg.ionizer == 1 reg15 = reg15 | 0x40 end
	if cfg.sleep == 1   reg15 = reg15 | 0x02 end
	if cfg.eco == 1     reg15 = reg15 | 0x01 end
	#NB: byte 16-21 are the MAC address per the protocol doc ; "beep" here is unconfirmed (writes byte 16)
	var reg16 = (cfg.beep == 0) ? 0x01 : 0x00 #byte 16 : 0x01 = no beep (UNCONFIRMED), 0x00 = beep
	if ac_mode != "off"
		reg12= ac_mode_values.find(ac_mode, 0x00) | 0x08
	else
		reg12=  0x00
	end

	#setting fan_speed on register 12 of the frame
	if ac_mode != "turbo"
		reg12 = reg12 |	fan_mode_values.find(fan_speed, 0x00)
	elif ac_mode == "turbo" #todo , check if its worth it to separate turbo mode
		reg12 = reg12 |	fan_mode_values.find(fan_speed, 0x00)
	end

	#setting swing mode (oscillation ouf louvres ) on register 14 of the frame
	reg14 = reg14 |	oscillation_mode_values.find(oscillation_mode, 0x00)

	#setting temperature setpoint on register 13
	reg13 = number(temperature_sp) - 16
	#clamp to a valid register value (0..15 => 16..31°C) to avoid a negative/out-of-range byte
	if reg13 < 0 reg13 = 0 end
	if reg13 > 15 reg13 = 15 end
	dprint("function forge_payload : Register 13 ,temperature setpoint :",temperature_sp," -16 : "  , reg13)

	#setting all the calculated parameters into the frame
	frame.set(12,reg12)
	frame.set(13,reg13)
	frame.set(14,reg14)
	frame.set(15,reg15)
	frame.set(16,reg16) #beep control

	#appending CRC
	frame.add(mod_crc16(frame),-2)
	return frame
end

#periodic Wi-Fi heartbeat (Frame AB, ESP->AC). The AC only uses it to keep the Wi-Fi icon lit on its
#display ; it expects no answer and there is no other effect. Constant 12-byte frame :
#7A 7A 21 D5 0C 00 00 AB 0A 0A + CRC16. Reschedules itself every 60 s.
def send_heartbeat()
	var frame = bytes("7A7A21D50C0000AB0A0A")
	frame.add(mod_crc16(frame), -2)        #same CRC idiom as forge_payload (hardware-confirmed)
	dprint("function send_heartbeat : sending Wi-Fi heartbeat (frame AB) : ", frame)
	ser.write(frame)
	tasmota.set_timer(60000, send_heartbeat, 3)
end

def mqtt_subscribe_dispatcher(topic, idx, payload_s, payload_b)
	var frame_to_send
	dprint("function mqtt_subscribe_dispatcher : message received from mqtt")
	dprint("function mqtt_subscribe_dispatcher : actual ac_mode = ", ac_mode)
	dprint("function mqtt_subscribe_dispatcher : actual fan_speed_setpoint = ", fan_speed_setpoint)
	dprint("function mqtt_subscribe_dispatcher : actual oscillation_mode_setpoint = ", oscillation_mode_setpoint)
	dprint("function mqtt_subscribe_dispatcher : actual temperature_setpoint = ", temperature_setpoint)
	# ensure we received a fisrt feedback from the AC unit
	if ac_mode == nil || fan_speed_setpoint == nil || oscillation_mode_setpoint == nil || temperature_setpoint == nil
		dprint("function mqtt_subscribe_dispatcher : Some of the variables are not yet received from AC unit , escaping")

		return
	end
	#we send back gratuitous feedback upon reception to ensure homeassistant gets immediate feedback and sets correctly its values (why doesnt Homeassistant have time setting for the feedback ? )
	if topic == (cfg.topic_prefix + "mode/set")
		ac_mode = payload_s
		dprint("function mqtt_subscribe_dispatcher : received ac_mode = ", ac_mode)
		mqtt.publish(cfg.feedback_topic_prefix + "mode/get" , ac_mode)
		dprint("function mqtt_subscribe_dispatcher : publishing immediately ac_mode")

	elif topic == (cfg.topic_prefix + "fan/set")
		fan_speed_setpoint = payload_s
		dprint("function mqtt_subscribe_dispatcher : received fan_speed_setpoint = ", fan_speed_setpoint)
		mqtt.publish(cfg.feedback_topic_prefix + "fan/get" , fan_speed_setpoint)
		dprint("function mqtt_subscribe_dispatcher : publishing immediately fan_speed_setpoint")

	elif topic == (cfg.topic_prefix + "swing/set")
		oscillation_mode_setpoint = payload_s
		dprint("function mqtt_subscribe_dispatcher : received oscillation_mode_setpoint = ", oscillation_mode_setpoint)
		mqtt.publish(cfg.feedback_topic_prefix + "swing/get" , oscillation_mode_setpoint)
		dprint("function mqtt_subscribe_dispatcher : publishing immediately oscillation_mode_setpoint")

	elif topic == (cfg.topic_prefix + "temperature/set")
		#the user setpoint is stored & reported verbatim. Any per-mode offset is applied later, only on the
		#frame actually sent to the AC (see the send block below), so HA always sees the user's target.
		temperature_setpoint = number(payload_s)
		dprint("function mqtt_subscribe_dispatcher : received user setpoint = ", temperature_setpoint)
		store_if_different(temperature_setpoint,"TempSetpoint")
		mqtt.publish(cfg.feedback_topic_prefix + "Actualsetpoint/get" , str(temperature_setpoint))

		#room-temperature reading (current mode's MQTT topic, or an HTTP poll via the sentinel) ; off-mode
		#readings are ignored so external_temp_value stays coherent with ac_mode. See NOTES.md.
	elif is_ext_topic(topic)
		var valid
		if topic == EXT_TEMP_HTTP
			valid = (reg_source(ac_mode) == "http")
		else
			valid = (reg_source(ac_mode) == "mqtt" && topic == reg_topic(ac_mode))
		end
		if !valid return end
		dprint("function mqtt_subscribe_dispatcher : external room temperature : ", number(payload_s) )
		external_temp_value = number(payload_s)
		global.berryton_state["external_temp"] = external_temp_value
		if cfg.ha_current_temp_source == "regulation"
			mqtt.publish(cfg.feedback_topic_prefix + "Actualtemp/get" , str(external_temp_value))
		end
	end
	# the hysteresis thermostat only runs when the ESP regulates (reg_source != "ac") ; in "ac" mode we skip
	# it entirely and thermostat_state stays nil (the send block short-circuits on it). See NOTES.md.
	var thermostat_state
	if reg_source(ac_mode) != "ac"
		#sanitize external_temp_value input (skip zero sometimes given by zigbee2mqtt and extremes temps)
		if external_temp_value < 1 || external_temp_value > 45
			# invalid reading : skip the regulation but keep going, so a user command is still sent
			dprint("function mqtt_subscribe_dispatcher : external temp out of range : skipping thermostat")
		else
			# 08/01/2025 we evaluate the thermostat on any payload reception
			thermostat_state = thermostat(temperature_setpoint,external_temp_value)
			dprint("function mqtt_subscribe_dispatcher : thermostat_state : " ,thermostat_state)
			if thermostat_state == nil
				dprint("function mqtt_subscribe_dispatcher : returned from thermostat function with nothing to do")
			elif thermostat_state
				if   ac_mode == "heat"
					temperature_setpoint_to_ac_unit = 31
				elif ac_mode == "cool"
					temperature_setpoint_to_ac_unit = 17
				end
			else
				if   ac_mode == "heat"
					temperature_setpoint_to_ac_unit = 17
				elif ac_mode == "cool"
					temperature_setpoint_to_ac_unit = 31
				end
			end
			store_if_different(temperature_setpoint_to_ac_unit , "temperature_setpoint_to_ac_unit")
			dprint("function mqtt_subscribe_dispatcher : thermostat function returned : ", thermostat_state)
			dprint("function mqtt_subscribe_dispatcher : temperature_setpoint_to_ac_unit :",temperature_setpoint_to_ac_unit,"°C")
		end
	end

	# decide which setpoint to forge into the frame sent to the AC
	var esp_regulates = reg_source(ac_mode) != "ac"
	if esp_regulates && (!is_ext_topic(topic) || thermostat_state != nil)
		#ESP hysteresis : push the forced 17/31°C value (resend on a command, or when the thermostat just flipped)
		dprint("function mqtt_subscribe_dispatcher : forging payload for ESP thermostat mode")
		frame_to_send = forge_payload(ac_mode, fan_speed_setpoint, oscillation_mode_setpoint, temperature_setpoint_to_ac_unit)
	elif !esp_regulates
		#AC regulates on its own sensor : push the user setpoint corrected by the per-mode offset (heat +, cool -)
		var off = reg_offset(ac_mode)
		var sp = (ac_mode == "heat") ? temperature_setpoint + off : ((ac_mode == "cool") ? temperature_setpoint - off : temperature_setpoint)
		dprint("function mqtt_subscribe_dispatcher : forging payload for AC-sensor mode, offset=", off, "°C → ", sp)
		frame_to_send = forge_payload(ac_mode, fan_speed_setpoint, oscillation_mode_setpoint, int(sp))
	end
	if frame_to_send != nil
		dprint("function mqtt_subscribe_dispatcher : sending frame to AC unit: ", frame_to_send)
		ser.write(frame_to_send)
	end
	return true
end

#apply a control command coming from the web UI panel, reusing the MQTT dispatcher path.
#kind is "mode" | "fan" | "swing" | "temperature".
def berryton_apply(kind, value)
	#optimistic UI update : reflect the command in the live state right away so the panel
	#updates immediately, without waiting for the AC to echo back a feedback frame.
	if   kind == "mode"        global.berryton_state["mode"] = value
	elif kind == "fan"         global.berryton_state["fan"] = value
	elif kind == "swing"       global.berryton_state["swing"] = value
	elif kind == "temperature" global.berryton_state["setpoint"] = value
	end
	mqtt_subscribe_dispatcher(cfg.topic_prefix + kind + "/set", 0, str(value), nil)
end
global.berryton_apply = berryton_apply

#expose the frame-processing entry so the serial-emulation module can inject synthetic A3 frames
global.berryton_feed_frame = get_frame_type

# avail variable contains the nr of char present in the serial buffer
def get_from_serial()
	var avail = ser.available()
	if avail != 0
		var msg = ser.read()
		ser.flush()
		if msg[0..1] == bytes("7A7A") && avail == msg.get(4,1)

		elif msg[0..1] == bytes("7A7A") && avail > msg.get(4,1)
			var msg2 = msg[msg.get(4,1)..size(msg)-1]
			msg = msg[0..msg.get(4,1)-1]
		end
		get_frame_type(msg)
	else
	end
end

#publish the Home Assistant MQTT climate autodiscovery config (retained) so HA creates the
#entity by itself. Topics mirror exactly what the script already listens to / publishes.
def publish_ha_discovery()
	if !cfg.ha_discovery_enabled return end
	#simplified menus by default ; the full set adds stepless + the sweep oscillation modes
	var fan_modes = ["auto","low","low-medium","medium","medium-high","high","turbo"]
	var swing_modes = ["off","on","high","medium-high","medium","medium-low","low"]
	if cfg.ha_full_command_set == 1
		fan_modes = ["auto","low","low-medium","medium","medium-high","high","stepless","turbo"]
		swing_modes = ["off","on","high","medium-high","medium","medium-low","low","sweep 1-5","sweep 2-5","sweep2-4","sweep1-4","sweep 1-3","sweep 4-6","sweep 3-5"]
	end
	var disco = {
		"name": cfg.ha_device_name,
		"unique_id": cfg.ha_unique_id,
		"modes": ["off","auto","cool","heat","dry","fan_only"],
		"fan_modes": fan_modes,
		"swing_modes": swing_modes,
		"min_temp": 16,
		"max_temp": 31,
		"temp_step": 1,
		"precision": 0.1,
		"mode_command_topic": cfg.topic_prefix + "mode/set",
		"mode_state_topic": cfg.feedback_topic_prefix + "mode/get",
		"fan_mode_command_topic": cfg.topic_prefix + "fan/set",
		"fan_mode_state_topic": cfg.feedback_topic_prefix + "fan/get",
		"swing_mode_command_topic": cfg.topic_prefix + "swing/set",
		"swing_mode_state_topic": cfg.feedback_topic_prefix + "swing/get",
		"temperature_command_topic": cfg.topic_prefix + "temperature/set",
		"temperature_state_topic": cfg.feedback_topic_prefix + "Actualsetpoint/get",
		"current_temperature_topic": cfg.feedback_topic_prefix + "Actualtemp/get",
		"device": {
			"identifiers": [cfg.ha_unique_id],
			"name": cfg.ha_device_name,
			"manufacturer": "Airton",
			"model": "TCL clone (Berryton)"
		}
	}
	var config_topic = "homeassistant/climate/" + cfg.ha_unique_id + "/config"
	mqtt.publish(config_topic, json.dump(disco), true)        #retain = true so HA picks it up anytime
	dprint("function publish_ha_discovery : published HA autodiscovery to ", config_topic)
end
#expose it so the separate config-page module can republish discovery after a settings change
global.berryton_publish_discovery = publish_ha_discovery

#extract the first number found in a string (handles "21.5", "21.4 C", or a simple JSON like {"t":-3.5})
#note : on a multi-field JSON it returns the FIRST number, so point the URL at a temperature-only endpoint
def extract_number(s)
	var out = ""
	var i = 0
	var started = false
	while i < size(s)
		var c = s[i]
		if (c >= "0" && c <= "9") || c == "." || (c == "-" && !started)
			out += c
			started = true
		elif started
			break
		end
		i += 1
	end
	return size(out) > 0 ? number(out) : nil
end

#build an HTTP room-temperature poller for one mode : polls reg_http_url(mode) every reg_http_interval(mode) s
#and feeds the dispatcher (via the HTTP sentinel) only while the AC is in that mode. See NOTES.md.
def make_http_poller(mode)
	def poller()
		if reg_source(mode) != "http" return end          #config changed (applies on restart) : stop the chain
		if ac_mode == mode && size(reg_http_url(mode)) > 0
			try
				var w = webclient()
				w.begin(reg_http_url(mode))
				var code = w.GET()
				if code == 200
					var t = extract_number(w.get_string())
					if t != nil
						dprint("poll_http_temp(", mode, ") : got ", t, "°C from ", reg_http_url(mode))
						#reuse the dispatcher's external-temperature path (sets external_temp_value + runs thermostat)
						mqtt_subscribe_dispatcher(EXT_TEMP_HTTP, 0, str(t), nil)
					else
						dprint("poll_http_temp(", mode, ") : no number found in HTTP body")
					end
				else
					dprint("poll_http_temp(", mode, ") : HTTP GET returned code ", code)
				end
				w.close()
			except .. as e, msg
				dprint("poll_http_temp(", mode, ") : exception ", e, " ", msg)
			end
		end
		tasmota.set_timer(reg_http_interval(mode) * 1000, poller, 2)
	end
	return poller
end

######### main program ########

dprint("starting program : mqtt topics", cfg.topic_prefix , cfg.feedback_topic_prefix )
mqtt.subscribe(cfg.topic_prefix + "mode/set",mqtt_subscribe_dispatcher)
mqtt.subscribe(cfg.topic_prefix + "fan/set",mqtt_subscribe_dispatcher)
mqtt.subscribe(cfg.topic_prefix + "swing/set",mqtt_subscribe_dispatcher)
mqtt.subscribe(cfg.topic_prefix + "temperature/set",mqtt_subscribe_dispatcher)
mqtt.subscribe("testsclim/payloadfromclim",mqtt_subscribe_dispatcher)
#external temperature : subscribe to the MQTT temp topic of every mode that uses an MQTT source (dedup)
var ext_subbed = {}
for m : ["heat", "cool"]
	if reg_source(m) == "mqtt"
		var t = reg_topic(m)
		if size(t) > 0 && !ext_subbed.contains(t)
			mqtt.subscribe(t, mqtt_subscribe_dispatcher)
			ext_subbed[t] = true
			dprint("external temp : MQTT source enabled (", m, ") on topic ", t)
		end
	end
end

#check if any temperature setpoint has been saved to flash
if persist.member("TempSetpoint") != nil
	dprint("persistance : retrieving temperature setpoint from tasmota flash")
	temperature_setpoint = number(persist.member("TempSetpoint"))
else
	dprint("persistance : setting a default temperature setpoint")
	temperature_setpoint = 20
	persist.TempSetpoint = temperature_setpoint
end

if persist.member("temperature_setpoint_to_ac_unit") != nil
	dprint("persistance : retrieving temperature_setpoint_to_ac_unit from tasmota flash")
	temperature_setpoint_to_ac_unit = number(persist.member("temperature_setpoint_to_ac_unit"))
else
	dprint("persistance : setting a default temperature_setpoint_to_ac_unit")
	temperature_setpoint_to_ac_unit = 17
	persist.temperature_setpoint_to_ac_unit = temperature_setpoint_to_ac_unit
end

#publish HA autodiscovery on every MQTT (re)connection, plus once now in case we are already connected
tasmota.add_rule("Mqtt#Connected", publish_ha_discovery)
publish_ha_discovery()

#start an HTTP temperature poller for each mode configured for HTTP
for m : ["heat", "cool"]
	if reg_source(m) == "http" && size(reg_http_url(m)) > 0
		dprint("external temp : HTTP source enabled (", m, "), polling ", reg_http_url(m), " every ", reg_http_interval(m), "s")
		make_http_poller(m)()
	end
end

#start the periodic Wi-Fi heartbeat (keeps the Wi-Fi icon lit on the AC display)
send_heartbeat()

def loop_me()
	# wrap in try/except so an unexpected exception never breaks the polling chain :
	# the timer is always rescheduled, otherwise serial polling would stop until reboot
	try
		get_from_serial()
	except .. as e, m
		dprint("function loop_me : exception caught in get_from_serial : ", e, " ", m)
	end
	tasmota.set_timer(200, loop_me, 1)
end
loop_me()

