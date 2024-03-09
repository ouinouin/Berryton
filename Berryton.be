#airton prtocol from me and brice (pingus.org)
#todo : implement quiet mode on the fan mode
#todo : check boost mode on the fan mode
#todo : publish autodiscovery for homeassistant
# crc snippet from  https://github.com/peepshow-21/ns-flash/blob/master/berry/nxpanel.be
import string
import mqtt
import persist

class Berryton
	static var topicprefix = "cmnd/Newclim/"					#the topic to receive the commands from
	static var FeedbackTopicPrefix = "tele/Newclim/"			#the topic to publish the the status of the AC unit
	var FanSpeedSetpoint 
	var OscillationModeSetpoint
	var TemperatureSetpoint
	var ACmode
	var incomingpayload
	static var externaltemptopic = "nodered/temp-salon"		#this is the mqtt topic containing the room temperature that you ll base external setpoint regulation on
	static var internalThermostat = 1							#change this to 0 to regulate only on internal Thermotat of the AC unit in heat mode
	var TemperatureSetpointToACunit
	static var TemperatureSetpointOffset = 8
	var last_thermostat_state
	# serial communications (pin 26 TX , PIN 32 RX , 9600 baud 8 N 1)
	#ser = serial(32, 26, 9600, serial.SERIAL_8N1)
	static var ser = serial(3, 4, 9600, serial.SERIAL_8N1)
	#an internal simple thermostat with fixes hysteresys symetrical : 0,3°C around the setpoint temperature.
	
	def thermostat(Setpoint,ActualTemp)
		
		print("function thermostat : last_thermostat_state before if: " , self.last_thermostat_state)
		print("function thermostat : setpoint : ", Setpoint , "actual temperature : ", ActualTemp , "delta : ", ActualTemp - Setpoint)
		if ActualTemp - Setpoint > 0.3 && self.last_thermostat_state!= 0
			print("function thermostat : temperature > setpoint")
			self.last_thermostat_state = 0
			print("function thermostat : last_thermostat_state Temp - Setpoint > 0.3 : " , self.last_thermostat_state)
			return 0
		elif (ActualTemp - Setpoint < -0.3 ) && self.last_thermostat_state!= 1
			print("function thermostat  : temperature < setpoint")
			self.last_thermostat_state = 1
			print("function thermostat : last_thermostat_state Temp - Setpoint < 0.3 : " , self.last_thermostat_state)
			return 1
		end
		print("function thermostat : no action")
	end


	#modbus CRC16
	def modcrc16(data, poly)	
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

	#checking messages incoming from AC unit CRC
	def CheckMessage(payload)
		#print(payload.size()) #debug
		var MsgCalCrc = self.modcrc16(payload[0..payload.size()-3])
		var MsgCrc = payload.get(payload.size()-2,-2) # last -2 param means endianness swap
		#print("calculated message = " , MsgCalCrc , "crc of payload = ", MsgCrc) #debug
		if MsgCalCrc == MsgCalCrc
			return 1
		else
			return 0
		end
	end

	#retrieve the AC unit mode from the AC unit frame	
	def GetACmode(payload) # available modes are : "auto","cool","dry","fan_only","heat"
		var ACmodelist = ["auto","cool","dry","fan_only","heat","off",]
		var ACmodeString = "auto"
		var AConOffState = 0
		#print("byte 13 : 0x" ,string.hex(payload[13]), " ACmode 3 bits value :", payload.getbits(106,1), payload.getbits(105,1), payload.getbits(104,1), " AC unit on/off state :", payload.getbits(107,1) ) #debug
		AConOffState = payload.getbits(107,1)
		if AConOffState == 1 
		ACmodeString = ACmodelist[payload.getbits(104,3)]
		else
		ACmodeString = ACmodelist[5]    
		end
		print("function GetACmode :  ACmodeString = " , ACmodeString ) #debug
		return ACmodeString
	end

	#retrieve the AC fan speed from the AC unit frame
	def GetFanSpeed(payload)
		var TurboModeState = 0
		var FanModeString = "auto"
		var FanModeList = ["auto","low","low-medium","medium","medium-high","high","stepless","turbo"]
		#print("byte 13 : 0x" ,string.hex(payload[13]), " FanSpeedMode 3 bits value :", payload.getbits(110,1), payload.getbits(109,1), payload.getbits(108,1), " mode turbo :", payload.getbits(111,1) ) #debug
		if TurboModeState == 0
		FanModeString = FanModeList[payload.getbits(108,3)]
		else
		FanModeString = FanModeList[7]
		end
		print( "function GetFanSpeed : FanModeString = " , FanModeString)
		return FanModeString
	end

	#retrieve the AC oscillation mode from the AC unit frame
	def GetOscillationMode(payload)
		var OscillationModeList = ["off", "on" ,"high","medium-high","medium","medium-low","low","sweep 3-5","sweep 3-5","sweep 2-5","sweep2-4","sweep1-4","sweep 1-3","sweep 4-6"]
		#print("function GetOscillationMode : byte 15 : 0x" ,string.hex(payload[15]), " Oscillation mode up/down 4 bits value :",payload.getbits(123,1), payload.getbits(122,1), payload.getbits(121,1), payload.getbits(120,1)) #debug
		var OscillationModeString = OscillationModeList[payload.getbits(120,4)]
		print ("function GetOscillationMode : OscillationModeString = ", OscillationModeString)
		return OscillationModeString
	end

	#retrieve the AC internal unit temperature sensor value from the AC unit frame
	def GetInternalTemperature(payload)
		var temperature = 0
		#print("byte 10 , ambient temperature integer part : " , payload.get(10,1) , "byte 11, ambient temperature decimal part: " , payload.get(11,1)   ) #debug
		temperature = real(payload.get(10,1)) + real(payload.get(11,1)) /10
		print("function GetInternalTemperature : internal unit temperature: ", temperature)
		return temperature
	end

	#retrieve the AC setpoint temperature
	def GetTemperatureSetpoint(payload)
		#print("byte 14 , setpoint temperature: " ,payload.getbits(115,1),payload.getbits(114,1), payload.getbits(113,1), payload.getbits(112,1) ) #debug
		#TemperatureSetpoint = payload.getbits(112,4) +16
		# will directly return the setpoint received by mqtt
		self.TemperatureSetpoint = number(persist.TempSetpoint)
		print("function GetTemperatureSetpoint : TemperatureSetpoint : ", self.TemperatureSetpoint)
		return self.TemperatureSetpoint
	end
		
	def PublishFeedback(payload)
		var MyACmode = self.GetACmode(payload)
		var MyFanSpeed = self.GetFanSpeed(payload)
		var MyOscillationMode = self.GetOscillationMode(payload)
		
		# sending back the temperature setpoint value minus the offset for the regulation to happen correctly
		var MyTemperature = str(self.GetInternalTemperature(payload) )
		if self.internalThermostat == 0
			self.TemperatureSetpoint = self.GetTemperatureSetpoint(payload) - self.TemperatureSetpointOffset
		else 
			self.TemperatureSetpoint = self.GetTemperatureSetpoint(payload)
		end
		#initialize settings value with first feedback from AC unit to manage restart conditions
		if 	self.FanSpeedSetpoint == nil self.FanSpeedSetpoint = MyFanSpeed  print("recovered FanSpeedSetpoint : " , self.FanSpeedSetpoint) end
		if 	self.OscillationModeSetpoint == nil self.OscillationModeSetpoint = MyOscillationMode print("recovered OscillationModeSetpoint : ", self.OscillationModeSetpoint) end
		if 	self.TemperatureSetpoint == nil self.TemperatureSetpoint =  print("recovered TemperatureSetpoint : ", self.TemperatureSetpoint) end
		if 	self.ACmode == nil self.ACmode = MyACmode print("recovered ACmode : ", self.ACmode) end
		
		print("function PublishFeedback : got all needed value, publishing in mqtt topics")
		mqtt.publish(self.FeedbackTopicPrefix + "mode/get" , MyACmode)
		#print("function PublishFeedback : published FanSpeedFeedback")
		mqtt.publish(self.FeedbackTopicPrefix + "fan/get" , MyFanSpeed)
		#print("function PublishFeedback : published FanSpeedFeedback")
		mqtt.publish(self.FeedbackTopicPrefix + "swing/get" , MyOscillationMode)
		#print("function PublishFeedback : published OscillationModeFeedback")
		mqtt.publish(self.FeedbackTopicPrefix + "Actualtemp/get" , MyTemperature)
		#print("function PublishFeedback : published TemperatureFeedback")
		mqtt.publish(self.FeedbackTopicPrefix + "Actualsetpoint/get" , str(self.TemperatureSetpoint))
		#print("function PublishFeedback : published Temperature_setpointFeedback")
		
	end
		
	def GetFrametype(payload)
		var FrameTypeString = "NONE" #frame A3 = feedback from AC unit to wifi module
		if self.CheckMessage(payload) == 1
			print("function GetFrametype : frame CRC seems valid")
			if payload.size() == 34
				print("function GetFrametype : seeking frame type on byte 7 : 0x" ,string.hex(payload[7]) ) #debug	
				if string.hex(payload[7]) == "A3"
					print("function GetFrametype : frame type is A3 : AC unit is giving back useful feedback")
					FrameTypeString = "ACFeedback"
					self.PublishFeedback(payload)
					return FrameTypeString
				else 
					print("function GetFrametype : frame is 34 bytes long but is not A3 type")
					return "INVALID_FRAME"
				end	
			else
				print("function GetFrametype : frame is not 34 bytes legnth")
			end
			
		else	
			print("function GetFrametype : CRC seems invalid, incomplete buffer ?")
			return "BADCRC"
		end	
		
	end	

		
	def forgepayload(Acmode,FanSpeed,OscillationMode,TemperatureSP)
		var frame = bytes("7A7A21D5180000A100000000" + "00000000" + "000000000000")
		#print("function forgepayload : empty frame= " ,frame)
		var ACmodeValues = {"auto": 0x00 , "cool" : 0x01 , "dry" : 0x02 , "fan_only" : 0x03 , "heat": 0x04 , "off" : 0x08}
		var FanModeValues = {"auto" : 0x00 ,"low" : 0x10 , "low-medium" : 0x20 ,"medium" : 0x30 , "medium-high" : 0x40 , "high" : 0x50 ,"stepless" : 0x60  ,"turbo" : 0x70 }
		var OscillationModeValues = {"off" : 0x00 , "on" : 0x01 ,"high" : 0x02 ,"medium-high" : 0x03 ,"medium" : 0x04 ,"medium-low" : 0x05 ,"low" : 0x06 ,"sweep 1-5" : 0x07 ,"sweep 2-5" : 0x08 ,"sweep2-4" : 0x09 ,"sweep1-4" : 0x0A ,"sweep 1-3" : 0x0B ,"sweep 4-6" : 0x0C ,"sweep 3-5": 0X0D}

		#setting ACmode on register 12 of the frame
		var Reg12 = 0x00
		var Reg13 = 0x00
		var Reg14 = 0x00
		var Reg15 = 0x98 #config word
		if Acmode != "off"
			Reg12= ACmodeValues[Acmode] | 0x08
		elif Acmode == "off"
			Reg12=  0x00
		end	
		
		#setting FanSpeed on register 12 of the frame
		if Acmode != "turbo"
			Reg12 = Reg12 |	FanModeValues[FanSpeed]
		elif Acmode == "turbo" #todo , check if its worth it to separate turbo mode
			Reg12 = Reg12 |	FanModeValues[FanSpeed]
		end	
		
		#setting swing mode (oscillation ouf louvres ) on register 14 of the frame
		Reg14 = Reg14 |	OscillationModeValues[OscillationMode]
		
		#setting temperature setpoint on register 13
		Reg13 = number(TemperatureSP) - 16
		print("function forgepayload : Register 13 ,temperature setpoint -16 : "  , Reg13)
					
		#print("function forgepayload : register 12 , AC mode and fanspeed :", string.hex(Reg12))
		#print("function forgepayload : register 13 , temperature setpoint :", string.hex(Reg13))
		#print("function forgepayload : register 14 , OscillationMode      :", string.hex(Reg14))
		#print("function forgepayload : register 15 , ConfigWord (todo)    :", string.hex(Reg15))
		#setting all the calculated parameters into the frame		
		frame.set(12,Reg12)
		frame.set(13,Reg13)
		frame.set(14,Reg14)
		frame.set(15,Reg15)	
		#print("function forgepayload : filled frame= " ,frame)
		
		#appending CRC
		self.modcrc16(frame)
		#print("function forgepayload : ", modcrc16(frame))
		frame.add(self.modcrc16(frame),-2)
		#print("function forgepayload : filled frame with crc = " ,frame)
		return frame
	end

	def MQTTSubscribeDispatcher(topic, idx, payload_s, payload_b)
		var frametosend
		print("function MQTTSubscribeDispatcher : message received from mqtt")
		print("function MQTTSubscribeDispatcher : actual ACmode = ", self.ACmode)
		print("function MQTTSubscribeDispatcher : actual FanSpeedSetpoint = ", self.FanSpeedSetpoint)
		print("function MQTTSubscribeDispatcher : actual OscillationModeSetpoint = ", self.OscillationModeSetpoint)
		print("function MQTTSubscribeDispatcher : actual TemperatureSetpoint = ", self.TemperatureSetpoint)
		# ensure we received a fisrt feedback from the AC unit 
		if self.ACmode == nil || self.FanSpeedSetpoint == nil || self.OscillationModeSetpoint == nil || self.TemperatureSetpoint == nil
			print("function MQTTSubscribeDispatcher : Some of the variables are not yet received , escaping")
			return
		end 
		#we send back gratuitous feedback upon reception to ensure homeassistant gets immediate feedback and sets correctly its values (why doesnt Homeassistant have time setting for the feedback ? )
		if topic == (self.topicprefix + "mode/set")
			self.ACmode = payload_s
			print("function MQTTSubscribeDispatcher : received ACmode = ", self.ACmode)
			mqtt.publish(self.FeedbackTopicPrefix + "mode/get" , self.ACmode)
			print("function MQTTSubscribeDispatcher : publishing immediately ACmode")
			
		elif topic == (self.topicprefix + "fan/set")
			self.FanSpeedSetpoint = payload_s
			print("function MQTTSubscribeDispatcher : received FanSpeedSetpoint = ", self.FanSpeedSetpoint)
			mqtt.publish(self.FeedbackTopicPrefix + "fan/get" , self.FanSpeedSetpoint)
			print("function MQTTSubscribeDispatcher : publishing immediately FanSpeedSetpoint")
			
		elif topic == (self.topicprefix + "swing/set")
			self.OscillationModeSetpoint = payload_s
			print("function MQTTSubscribeDispatcher : received OscillationModeSetpoint = ", self.OscillationModeSetpoint)
			mqtt.publish(self.FeedbackTopicPrefix + "swing/get" , self.OscillationModeSetpoint)
			print("function MQTTSubscribeDispatcher : publishing immediately OscillationModeSetpoint")
		
		elif topic == (self.topicprefix + "temperature/set")
			#some offset trials , the feedback is the temperature without the offset
			print("function MQTTSubscribeDispatcher : received TemperatureSetpoint = ", self.TemperatureSetpoint)
			if self.ACmode == "heat" && self.internalThermostat == 0
				self.TemperatureSetpoint = number((payload_s)) + self.TemperatureSetpointOffset
				print("function MQTTSubscribeDispatcher : heating mode, applying offset of :" , self.TemperatureSetpointOffset , "°C")
			end
			if self.ACmode == "heat" && self.internalThermostat == 1
				print("function MQTTSubscribeDispatcher : internal_thermostat enabled : saving the setpoint to persistance file") 
				self.TemperatureSetpoint = number(payload_s)
				persist.TempSetpoint = self.TemperatureSetpoint
			end
			print("function MQTTSubscribeDispatcher : publishing immediately TemperatureSetpoint")
			mqtt.publish(self.FeedbackTopicPrefix + "Actualsetpoint/get" , payload_s)
			
		
		#on external temperature reception, we trigger the thermostat, we dont
		#stop the unit but give a  lower temperature (17°C) to force the AC unit 
		#to pause with louvre open
		elif topic == self.externaltemptopic && self.internalThermostat == 1 
			print("function MQTTSubscribeDispatcher : received a temperature value from external thermometer : ", number(payload_s) )
			var thermostat_state = self.thermostat(self.TemperatureSetpoint,number(payload_s))
			print("function MQTTSubscribeDispatcher : thermostat_state : " ,thermostat_state)
				if thermostat_state == 1
					print("function MQTTSubscribeDispatcher : thermostat function returned 1 , sending frame with 31°C to AC unit")
					self.TemperatureSetpointToACunit = 31
					persist.TemperatureSetpointToACunit = self.TemperatureSetpointToACunit
					frametosend = self.forgepayload(self.ACmode,self.FanSpeedSetpoint,self.OscillationModeSetpoint,self.TemperatureSetpointToACunit)
					self.ser.write(frametosend)
					return
				elif thermostat_state == 0
					print("function MQTTSubscribeDispatcher : thermostat function returned 0 , sending frame with 17°C to AC unit")
					self.TemperatureSetpointToACunit = 17
					persist.TemperatureSetpointToACunit = self.TemperatureSetpointToACunit
					frametosend = self.forgepayload(self.ACmode,self.FanSpeedSetpoint,self.OscillationModeSetpoint,self.TemperatureSetpointToACunit)
					self.ser.write(frametosend)
					return
				end

			return
		end
	
		# in thermostat mode we publish back the temperature setpoint we receive instead of the internal setpoint since we re playing with the internal setpoint
		if self.internalThermostat == 1
			frametosend = self.forgepayload(self.ACmode,self.FanSpeedSetpoint,self.OscillationModeSetpoint,self.TemperatureSetpointToACunit)
		else
			frametosend = self.forgepayload(self.ACmode,self.FanSpeedSetpoint,self.OscillationModeSetpoint,int(self.TemperatureSetpoint))
		end

		print("function MQTTSubscribeDispatcher : sending frame to AC unit: ", frametosend)
		self.ser.write(frametosend)
		return true
	end


	def every_250ms()
		var avail = self.ser.available()
		if avail != 0
			var msg = self.ser.read()
			self.ser.flush()
			if msg[0..1] == bytes("7A7A") && avail == msg.get(4,1)
				#print("function every_250ms : buffer filled with :", avail , " bytes")
				#print ("function every_250ms : message length :", msg.get(4,1))
				print("function every_250ms : message from AC unit :", msg.tostring(60))
			
			elif msg[0..1] == bytes("7A7A") && avail > msg.get(4,1)
				print ("function every_250ms : buffer is bigger than frame, cutting frame")
				var msg2 = msg[msg.get(4,1)..size(msg)-1]
				msg = msg[0..msg.get(4,1)-1]
				print("function every_250ms : message from AC unit :", msg.tostring(60))
				print("function every_250ms : remaining msg   :", msg2.tostring(60)) #todo , implement a buffer of frames.
			end
			print("function every_250ms : calling GetFrametype(msg)")
			self.GetFrametype(msg)
		else 
		#	print ("function every_250ms : nothing in the buffer")
		end
	end

	######### main program ########
	def init()
		print("starting program : mqtt topics", self.topicprefix , self.FeedbackTopicPrefix )
		#todo loop all the topics
		mqtt.subscribe(self.topicprefix + "mode/set", /topic,idx,payload_s,payload_b-> self.MQTTSubscribeDispatcher(topic,idx,payload_s,payload_b)) # this works
		mqtt.subscribe(self.topicprefix + "fan/set", /topic,idx,payload_s,payload_b-> self.MQTTSubscribeDispatcher(topic,idx,payload_s,payload_b)) # this works
		mqtt.subscribe(self.topicprefix + "swing/set", /topic,idx,payload_s,payload_b-> self.MQTTSubscribeDispatcher(topic,idx,payload_s,payload_b)) # this works
		mqtt.subscribe(self.topicprefix + "temperature/set", /topic,idx,payload_s,payload_b-> self.MQTTSubscribeDispatcher(topic,idx,payload_s,payload_b)) # this works
		mqtt.subscribe(self.topicprefix + "testsclim/payloadfromclim", /topic,idx,payload_s,payload_b-> self.MQTTSubscribeDispatcher(topic,idx,payload_s,payload_b)) # this works
		mqtt.subscribe(self.topicprefix + self.externaltemptopic, /topic,idx,payload_s,payload_b-> self.MQTTSubscribeDispatcher(topic,idx,payload_s,payload_b)) # this works

		#check if any temperature setpoint has been saved to flash
		if persist.member("TempSetpoint") != nil
			print("persistance : retrieving temperature setpoint from tasmota flash")
			self.TemperatureSetpoint = number(persist.member("TempSetpoint"))
		else
			print("persistance : setting a default temperature setpoint")
			self.TemperatureSetpoint = 20
			persist.TemperatureSetpoint = self.TemperatureSetpointToACunit
		end

		if persist.member("TemperatureSetpointToACunit") != nil
			print("persistance : retrieving TemperatureSetpointToACunit from tasmota flash")
			self.TemperatureSetpointToACunit = number(persist.member("TemperatureSetpointToACunit"))
		else
			print("persistance : setting a default TemperatureSetpointToACunit")
			self.TemperatureSetpointToACunit = 17
			persist.TemperatureSetpointToACunit = self.TemperatureSetpointToACunit
		end
	end

	def web_sensor()
		tasmota.web_send_decimal("mymessage")
		#{s}: start of line
		#{m}: separator between name and value
		#{e}: end of line
		var msg = string.format(
			"{s}ACmode{m}%s G{e}"..    
			"{s}TemperatureSetpoint{m}%f {e}"..
			"{s}FanSpeedSetpoint{m}%s {e}"..
			"{s}OscillationModeSetpoint{m}%s dps{e}", self.ACmode, self.TemperatureSetpoint, self.FanSpeedSetpoint , self.OscillationModeSetpoint)
	end

end

Berryton = Berryton()
tasmota.add_driver(Berryton)
