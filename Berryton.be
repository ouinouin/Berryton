#airton protocol from me and brice (pingus.org)
#todo : implement quiet mode on the fan mode
#todo : check boost mode on the fan mode
#todo : publish autodiscovery for homeassistant
# crc snippet from  https://github.com/peepshow-21/ns-flash/blob/master/berry/nxpanel.be

import string
import mqtt
import persist
import introspect

var topic_prefix = "cmnd/Newclim/"
var feedback_topic_prefix = "tele/Newclim/"
var fan_speed_setpoint
var oscillation_mode_setpoint
var temperature_setpoint
var ac_mode
var external_temp_topic = "nodered/temp-salon"
var internal_thermostat = 1 							#1=enables the hysteresis logic in the code 0 to let the AC unit drive its regulation + adding temperature_setpoint_offset
var hyst = 0.3 										#hysteresis (in °C) used by the internal thermostat (internal_thermostat=1)
var debug = 1 										#1=print debug messages on the console, 0=stay silent
var temperature_setpoint_to_ac_unit
var external_temp_value = 19 							# set to a value in case the temperature update from an external sensor is long.

var temperature_setpoint_offset = 8
# serial communications (pin 26 TX , PIN 32 RX)
ser = serial(32, 26, 9600, serial.SERIAL_8N1)

#debug print helper : prints only when debug is enabled, so there is no need for an "if debug" around every call
def dprint(*args)
	if !debug return end
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
	if (delta > hyst ) && last_thermostat_state!= 0
		dprint("function thermostat : delta > hyst")
		last_thermostat_state = 0
		dprint("function thermostat : last_thermostat_state=",last_thermostat_state)
		return 0

	elif (delta < -hyst ) && last_thermostat_state!= 1
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
	#dprint(payload.size()) #debug
	var msg_cal_crc = mod_crc16(payload[0..payload.size()-3])
	var msg_crc = payload.get(payload.size()-2,-2) # last -2 param means endianness swap
	#dprint("calculated message = " , msg_cal_crc , "crc of payload = ", msg_crc) #debug
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
	#dprint("byte 13 : 0x" ,string.hex(payload[13]), " ac_mode 3 bits value :", payload.getbits(106,1), payload.getbits(105,1), payload.getbits(104,1), " AC unit on/off state :", payload.getbits(107,1) ) #debug
	ac_on_off_state = payload.getbits(107,1)
	if ac_on_off_state == 1
		ac_mode_string = ac_mode_list[payload.getbits(104,3)]
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
	#dprint("byte 13 : 0x" ,string.hex(payload[13]), " FanSpeedMode 3 bits value :", payload.getbits(110,1), payload.getbits(109,1), payload.getbits(108,1), " mode turbo :", payload.getbits(111,1) ) #debug
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
	#dprint("function get_oscillation_mode : byte 15 : 0x" ,string.hex(payload[15]), " Oscillation mode up/down 4 bits value :",payload.getbits(123,1), payload.getbits(122,1), payload.getbits(121,1), payload.getbits(120,1)) #debug
	var oscillation_mode_string = oscillation_mode_list[payload.getbits(120,4)]
	dprint("function get_oscillation_mode : oscillation_mode_string = ", oscillation_mode_string)
	return oscillation_mode_string
end

#retrieve the AC internal unit temperature sensor value from the AC unit frame
def get_internal_temperature(payload)
	var temperature = 0
	#dprint("byte 10 , ambient temperature integer part : " , payload.get(10,1) , "byte 11, ambient temperature decimal part: " , payload.get(11,1)   ) #debug
	temperature = real(payload.get(10,1)) + real(payload.get(11,1)) /10
	dprint("function get_internal_temperature : internal unit temperature: ", temperature)
	return temperature
end

#retrieve the AC setpoint temperature
def get_temperature_setpoint(payload)
	#dprint("byte 14 , setpoint temperature: " ,payload.getbits(115,1),payload.getbits(114,1), payload.getbits(113,1), payload.getbits(112,1) ) #debug
	if internal_thermostat == 0
		temperature_setpoint = payload.getbits(112,4) +16
		store_if_different(temperature_setpoint,"TempSetpoint")
		dprint("function get_temperature_setpoint : temperature_setpoint retrieved on payload from ACunit : ", temperature_setpoint)
		# will directly return the setpoint received by mqtt
		#there is a catch here , this function has to be reworked in order to ensure a good sync while using infrared remote
	else
		temperature_setpoint = number(persist.TempSetpoint)
		dprint("function get_temperature_setpoint : temperature_setpoint retrieved from persistent memory : ", temperature_setpoint)
	end
	return temperature_setpoint
end

def publish_feedback(payload)
	var my_ac_mode = get_ac_mode(payload)
	var my_fan_speed = get_fan_speed(payload)
	var my_oscillation_mode = get_oscillation_mode(payload)

	# sending back the temperature setpoint value minus the offset for the regulation to happen correctly
	var my_temperature = str(get_internal_temperature(payload) )
	if internal_thermostat == 0
		temperature_setpoint = get_temperature_setpoint(payload) - temperature_setpoint_offset
	else
		temperature_setpoint = get_temperature_setpoint(payload)
	end
	#initialize settings value with first feedback from AC unit to manage restart conditions
	if fan_speed_setpoint == nil fan_speed_setpoint = my_fan_speed  dprint("recovered fan_speed_setpoint : " , fan_speed_setpoint) end
	if oscillation_mode_setpoint == nil oscillation_mode_setpoint = my_oscillation_mode dprint("recovered oscillation_mode_setpoint : ", oscillation_mode_setpoint) end
	if temperature_setpoint == nil dprint("no temperature_setpoint available, check persistance file value :", temperature_setpoint) end
	if ac_mode == nil ac_mode = my_ac_mode dprint("recovered ac_mode : ", ac_mode) end


	dprint("function publish_feedback : got all needed value, publishing in mqtt topics")
	mqtt.publish(feedback_topic_prefix + "mode/get" , my_ac_mode)
	#dprint("function publish_feedback : published FanSpeedFeedback")
	mqtt.publish(feedback_topic_prefix + "fan/get" , my_fan_speed)
	#dprint("function publish_feedback : published FanSpeedFeedback")
	mqtt.publish(feedback_topic_prefix + "swing/get" , my_oscillation_mode)
	#dprint("function publish_feedback : published OscillationModeFeedback")
	mqtt.publish(feedback_topic_prefix + "Actualtemp/get" , my_temperature)
	#dprint("function publish_feedback : published TemperatureFeedback")
	mqtt.publish(feedback_topic_prefix + "Actualsetpoint/get" , str(temperature_setpoint))
	#dprint("function publish_feedback : published Temperature_setpointFeedback")

end

def get_frame_type(payload)
	var frame_type_string = "NONE" #frame A3 = feedback from AC unit to wifi module
	if check_message(payload) == 1
		#dprint("function get_frame_type : frame CRC seems valid")
		if payload.size() == 34
			#dprint("function get_frame_type : seeking frame type on byte 7 : 0x" ,string.hex(payload[7]) ) #debug

			if string.hex(payload[7]) == "A3"
				#dprint("function get_frame_type : frame type is A3 : AC unit is giving back useful feedback")
				dprint("function get_frame_type : valid message from AC unit :", payload.tostring(60))
				frame_type_string = "ACFeedback"
				publish_feedback(payload)
				return frame_type_string
			else
				#dprint("function get_frame_type : frame is 34 bytes long but is not A3 type")
				return "INVALID_FRAME"
			end
		else
			#dprint("function get_frame_type : frame is not 34 bytes legnth")
		end

	else
		#dprint("function get_frame_type : CRC seems invalid, incomplete buffer ?")
		return "BADCRC"
	end

end


def forge_payload(ac_mode,fan_speed,oscillation_mode,temperature_sp)
	var frame = bytes("7A7A21D5180000A100000000" + "00000000" + "000000000000")
	#dprint("function forge_payload : empty frame= " ,frame)
	var ac_mode_values = {"auto": 0x00 , "cool" : 0x01 , "dry" : 0x02 , "fan_only" : 0x03 , "heat": 0x04 , "off" : 0x08}
	var fan_mode_values = {"auto" : 0x00 ,"low" : 0x10 , "low-medium" : 0x20 ,"medium" : 0x30 , "medium-high" : 0x40 , "high" : 0x50 ,"stepless" : 0x60  ,"turbo" : 0x70 }
	var oscillation_mode_values = {"off" : 0x00 , "on" : 0x01 ,"high" : 0x02 ,"medium-high" : 0x03 ,"medium" : 0x04 ,"medium-low" : 0x05 ,"low" : 0x06 ,"sweep 1-5" : 0x07 ,"sweep 2-5" : 0x08 ,"sweep2-4" : 0x09 ,"sweep1-4" : 0x0A ,"sweep 1-3" : 0x0B ,"sweep 4-6" : 0x0C ,"sweep 3-5": 0X0D}

	#setting ac_mode on register 12 of the frame
	var reg12 = 0x00
	var reg13 = 0x00
	var reg14 = 0x00
	var reg15 = 0x98 #config word
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

	#dprint("function forge_payload : register 12 , AC mode and fanspeed :", string.hex(reg12))
	#dprint("function forge_payload : register 13 , temperature setpoint :", string.hex(reg13))
	#dprint("function forge_payload : register 14 , oscillation_mode      :", string.hex(reg14))
	#dprint("function forge_payload : register 15 , ConfigWord (todo)    :", string.hex(reg15))
	#setting all the calculated parameters into the frame
	frame.set(12,reg12)
	frame.set(13,reg13)
	frame.set(14,reg14)
	frame.set(15,reg15)
	#dprint("function forge_payload : filled frame= " ,frame)

	#appending CRC
	#dprint("function forge_payload : ", mod_crc16(frame))
	frame.add(mod_crc16(frame),-2)
	#dprint("function forge_payload : filled frame with crc = " ,frame)
	return frame
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
	if topic == (topic_prefix + "mode/set")
		ac_mode = payload_s
		dprint("function mqtt_subscribe_dispatcher : received ac_mode = ", ac_mode)
		mqtt.publish(feedback_topic_prefix + "mode/get" , ac_mode)
		dprint("function mqtt_subscribe_dispatcher : publishing immediately ac_mode")

	elif topic == (topic_prefix + "fan/set")
		fan_speed_setpoint = payload_s
		dprint("function mqtt_subscribe_dispatcher : received fan_speed_setpoint = ", fan_speed_setpoint)
		mqtt.publish(feedback_topic_prefix + "fan/get" , fan_speed_setpoint)
		dprint("function mqtt_subscribe_dispatcher : publishing immediately fan_speed_setpoint")

	elif topic == (topic_prefix + "swing/set")
		oscillation_mode_setpoint = payload_s
		dprint("function mqtt_subscribe_dispatcher : received oscillation_mode_setpoint = ", oscillation_mode_setpoint)
		mqtt.publish(feedback_topic_prefix + "swing/get" , oscillation_mode_setpoint)
		dprint("function mqtt_subscribe_dispatcher : publishing immediately oscillation_mode_setpoint")

	elif topic == (topic_prefix + "temperature/set")
		#some offset trials , the feedback is the temperature without the offset
		dprint("function mqtt_subscribe_dispatcher : received temperature_setpoint = ", number(payload_s))

		if ac_mode == "heat" && internal_thermostat == 0
			temperature_setpoint = number(payload_s) + temperature_setpoint_offset
			dprint("function mqtt_subscribe_dispatcher : heating mode, applying positive offset of :" , temperature_setpoint_offset , "°C")

		elif internal_thermostat == 1
			temperature_setpoint = number(payload_s)
			dprint("function mqtt_subscribe_dispatcher : internal_thermostat enabled in : ", ac_mode, " mode : saving the setpoint: ",temperature_setpoint , " to persistance file if different then previously")


		elif ac_mode == "cool" && internal_thermostat == 0
			temperature_setpoint = number(payload_s) - temperature_setpoint_offset
			dprint("function mqtt_subscribe_dispatcher : cooling mode, applying negative offset of :" , temperature_setpoint_offset , "°C")


		end
		store_if_different(temperature_setpoint,"TempSetpoint")
		dprint("function mqtt_subscribe_dispatcher : publishing immediately temperature_setpoint")
		mqtt.publish(feedback_topic_prefix + "Actualsetpoint/get" , payload_s)


		#on external temperature reception, we trigger the thermostat, we dont
		#stop the unit but give :
		# a  lower temperature setpoint (17°C) while in heat mode
		# a higher temperature setpoint (31°c) while in cool mode
		#to force the AC unit
		#to pause with louvre open
	elif topic == external_temp_topic && internal_thermostat == 1
		dprint("function mqtt_subscribe_dispatcher : received a temperature value from external thermometer : ", number(payload_s) )
		external_temp_value = number(payload_s)
	end
	#sanitize external_temp_value input (skip zero sometimes given by zigbee2mqtt and extremes temps)
	if external_temp_value < 1 || external_temp_value > 45
		dprint("function mqtt_subscribe_dispatcher : value out of range : waiting for valid value")
		return
	end
	# 08/01/2025 we now evaluate the thermostat on any payload reception
	var thermostat_state = thermostat(temperature_setpoint,external_temp_value)
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

	# in thermostat mode we send back the external setpoint #
	if(internal_thermostat == 1 &&  topic != external_temp_topic) || (internal_thermostat == 1 && thermostat_state != nil)
		dprint("function mqtt_subscribe_dispatcher : forging payload for internal thermostat mode")
		frame_to_send = forge_payload(ac_mode, fan_speed_setpoint, oscillation_mode_setpoint, temperature_setpoint_to_ac_unit)
	elif(internal_thermostat == 0)
		dprint("function mqtt_subscribe_dispatcher : forging payload for AC unit thermostat + offset mode")
		frame_to_send = forge_payload(ac_mode, fan_speed_setpoint, oscillation_mode_setpoint, int(temperature_setpoint))
	end
	if frame_to_send != nil
		dprint("function mqtt_subscribe_dispatcher : sending frame to AC unit: ", frame_to_send)
		ser.write(frame_to_send)
	end
	return true
end

# avail variable contains the nr of char present in the serial buffer
def get_from_serial()
	var avail = ser.available()
	if avail != 0
		var msg = ser.read()
		ser.flush()
		if msg[0..1] == bytes("7A7A") && avail == msg.get(4,1)
			#dprint("function get_from_serial : buffer filled with :", avail , " bytes")
			#dprint ("function get_from_serial : message length :", msg.get(4,1))
			#dprint("function get_from_serial : message from AC unit :", msg.tostring(60))

		elif msg[0..1] == bytes("7A7A") && avail > msg.get(4,1)
			#dprint ("function get_from_serial : buffer is bigger than frame, cutting frame")
			var msg2 = msg[msg.get(4,1)..size(msg)-1]
			msg = msg[0..msg.get(4,1)-1]
			#dprint("function get_from_serial : message from AC unit :", msg.tostring(60))
			#dprint("function get_from_serial : remaining msg   :", msg2.tostring(60)) #todo , implement a buffer of frames.
		end
		#dprint("function get_from_serial : calling get_frame_type(msg)")
		get_frame_type(msg)
	else
		#	dprint ("function get_from_serial : nothing in the buffer")
	end
end

######### main program ########

dprint("starting program : mqtt topics", topic_prefix , feedback_topic_prefix )
mqtt.subscribe(topic_prefix + "mode/set",mqtt_subscribe_dispatcher)
mqtt.subscribe(topic_prefix + "fan/set",mqtt_subscribe_dispatcher)
mqtt.subscribe(topic_prefix + "swing/set",mqtt_subscribe_dispatcher)
mqtt.subscribe(topic_prefix + "temperature/set",mqtt_subscribe_dispatcher)
mqtt.subscribe("testsclim/payloadfromclim",mqtt_subscribe_dispatcher)
mqtt.subscribe(external_temp_topic,mqtt_subscribe_dispatcher)

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

def loop_me()
	get_from_serial()
	tasmota.set_timer(200, loop_me, 1)
end
loop_me()

