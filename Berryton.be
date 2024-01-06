#airton prtocol from me and brice (pingus.org)
#https://owncloud.pingus.org/nextcloud/index.php/s/nKFyHX9TK63BWGo
#todo : implement quiet mode on the fan mode
#todo : check boost mode on the fan mode
#todo publish autodiscovery for homeassistant
# crc snippet from  https://github.com/peepshow-21/ns-flash/blob/master/berry/nxpanel.be
import string
import mqtt

var topicprefix = "cmnd/Newclim/"
var FeedbackTopicPrefix = "tele/Newclim/"
var FanSpeedSetpoint 
var OscillationModeSetpoint
var TemperatureSetpoint
var ACmode
var incomingpayload = bytes()
TemperatureSetpointOffset = 8
print("mqtt topics", topicprefix , FeedbackTopicPrefix )
# serial communications (pin 26 TX , PIN 32 RX)
ser = serial(32, 26, 9600, serial.SERIAL_8N1)


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

def CheckMessage(payload)
   print(payload.size()) #debug
   var MsgCalCrc = modcrc16(payload[0..payload.size()-3])
   var MsgCrc = payload.get(payload.size()-2,-2) # last -2 param means endianness swap
   #print("calculated message = " , MsgCalCrc , "crc of payload = ", MsgCrc) #debug
   if MsgCalCrc == MsgCalCrc
	 return 1
   else
	 return 0
   end
end






	
	def GetACmode(payload) # available modes are : "auto","cool","dry","fan_only","heat"
		var ACmodelist = ["auto","cool","dry","fan_only","heat","off",]
		var ACmodeString = "auto"
		var AConOffState = 0
	    print("byte 13 : 0x" ,string.hex(payload[13]), " ACmode 3 bits value :", payload.getbits(106,1), payload.getbits(105,1), payload.getbits(104,1), " AC unit on/off state :", payload.getbits(107,1) ) #debug
	    AConOffState = payload.getbits(107,1)
	    if AConOffState == 1 
	    ACmodeString = ACmodelist[payload.getbits(104,3)]
	    else
	    ACmodeString = ACmodelist[5]    
	    end
	    print(" ACmodeString = " , ACmodeString ) #debug
	    return ACmodeString
	end

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
		print( "FanModeString = " , FanModeString)
		return FanModeString
	end
	
	def GetOscillationMode(payload)
		var OscillationModeList = ["off", "on" ,"high","medium-high","medium","medium-low","low","sweep 3-5","sweep 3-5","sweep 2-5","sweep2-4","sweep1-4","sweep 1-3","sweep 4-6"]
		print("byte 15 : 0x" ,string.hex(payload[15]), " Oscillation mode up/down 4 bits value :",payload.getbits(123,1), payload.getbits(122,1), payload.getbits(121,1), payload.getbits(120,1)) #debug
		var OscillationModeString = OscillationModeList[payload.getbits(120,4)]
		print ("OscillationModeString = ", OscillationModeString)
		return OscillationModeString
	end
	
	def GetTemperature(payload)
	    var temperature = 0
	    #print("byte 10 , ambient temperature integer part : " , payload.get(10,1) , "byte 11, ambient temperature decimal part: " , payload.get(11,1)   ) #debug
		temperature = real(payload.get(10,1)) + real(payload.get(11,1)) /10
		print("decoded temperature: ", temperature)
		return temperature
	end
	
	def GetTemperatureSetpoint(payload)
		var TemperatureSetpoint = 20
		#print("byte 14 , setpoint temperature: " ,payload.getbits(115,1),payload.getbits(114,1), payload.getbits(113,1), payload.getbits(112,1) ) #debug
		TemperatureSetpoint = payload.getbits(112,4) +16
		print("TemperatureSetpoint = ", TemperatureSetpoint)
		return TemperatureSetpoint
	end
	

	def PublishFeedback(payload)
		var MyACmode = GetACmode(payload)
		var MyFanSpeed = GetFanSpeed(payload)
		var MyOscillationMode = GetOscillationMode(payload)
		
		# sending back the temperature setpoint value minus the offset for the regulation to happen correctly
		var MyTemperature = str(GetTemperature(payload) )
		var MyTemperatureSetpoint = str(GetTemperatureSetpoint(payload)- TemperatureSetpointOffset)
		
		#initialize sttings value with first feedback from AC unit to manage restart conditions
		if FanSpeedSetpoint == nil FanSpeedSetpoint = MyFanSpeed  print("recovered FanSpeedSetpoint : " , FanSpeedSetpoint) end
		if OscillationModeSetpoint == nil OscillationModeSetpoint = MyOscillationMode print("recovered OscillationModeSetpoint : ", OscillationModeSetpoint) end
		if TemperatureSetpoint == nil TemperatureSetpoint = MyTemperatureSetpoint print("recovered TemperatureSetpoint : ", TemperatureSetpoint) end
		if ACmode == nil ACmode = MyACmode print("recovered ACmode : ", ACmode) end
		
		
		print("got all needed value, publishing in mqtt topics")
		
		mqtt.publish(FeedbackTopicPrefix + "mode/get" , MyACmode)
		#print("published FanSpeedFeedback")
		
		mqtt.publish(FeedbackTopicPrefix + "fan/get" , MyFanSpeed)
		#print("published FanSpeedFeedback")
		
		mqtt.publish(FeedbackTopicPrefix + "swing/get" , MyOscillationMode)
		#print("published OscillationModeFeedback")
		
		mqtt.publish(FeedbackTopicPrefix + "Actualtemp/get" , MyTemperature)
		#print("published TemperatureFeedback")
		
		mqtt.publish(FeedbackTopicPrefix + "Actualsetpoint/get" , MyTemperatureSetpoint)
		#print("published Temperature_setpointFeedback")
		
	end
	
	def GetFrametype(payload)
		var FrameTypeString = "NONE" #frame A3 = feedback from AC unit to wifi module
	    if CheckMessage(payload) == 1
	        if payload.size() == 34
				print("byte 7 : 0x" ,string.hex(payload[7]) ) #debug	
				if string.hex(payload[7]) == "A3"
					print("frame type A3 : AC unit is giving back useful feedback")
					FrameTypeString = "ACFeedback"
					PublishFeedback(payload)
					return FrameTypeString
				else 
					print("frame is not A3 type")
					return "INVALID_FRAME"
				end	
			print("frame is not 34 bytes legnth")
			end
			
		else	
			print("CRC seems invalid, incomplete buffer ?")
			return "BADCRC"
		end	
		
	end	




	
	def forgepayload(Acmode,FanSpeed,OscillationMode,TemperatureSP)
	    var frame = bytes("7A7A21D5180000A100000000" + "00000000" + "000000000000")
	    #print("empty frame= " ,frame)
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
		#print("type reg13" , type(Reg13))
					
		#print("register 12 , AC mode and fanspeed :", string.hex(Reg12))
		#print("register 13 , temperature setpoint :", string.hex(Reg13))
		#print("register 14 , OscillationMode      :", string.hex(Reg14))
		#print("register 15 , ConfigWord (todo)    :", string.hex(Reg15))
		#setting all the calculated parameters into the frame		
		frame.set(12,Reg12)
		frame.set(13,Reg13)
		frame.set(14,Reg14)
		frame.set(15,Reg15)	
		#print("filled frame= " ,frame)
		
		#appending CRC
		modcrc16(frame)
		#print(modcrc16(frame))
		frame.add(modcrc16(frame),-2)
		#print("filled frame with crc = " ,frame)
		return frame
	end

	def f(topic, idx, payload_s, payload_b)
	  print("message received from mqtt")
	  print("actual ACmode = ", ACmode)
	  print("actual FanSpeedSetpoint = ", FanSpeedSetpoint)
	  print("actual OscillationModeSetpoint = ", OscillationModeSetpoint)
	  print("actual TemperatureSetpoint = ", TemperatureSetpoint)
	 
	  #we send back gratuitous feedback upon reception to ensure homeassistant gets immediate feedback and sets correctly its values (why doesnt Homeassistant have time setting for the feedback ? )
	  if topic == (topicprefix + "mode/set")
	    ACmode = payload_s
	    print("received ACmode = ", ACmode)
	    
	    mqtt.publish(FeedbackTopicPrefix + "mode/get" , ACmode)
		print("publishing immediately ACmode")
		
	  elif topic == (topicprefix + "fan/set")
		FanSpeedSetpoint = payload_s
		print("received FanSpeedSetpoint = ", FanSpeedSetpoint)
		mqtt.publish(FeedbackTopicPrefix + "fan/get" , FanSpeedSetpoint)
		print("publishing immediately FanSpeedSetpoint")
		
	  elif topic == (topicprefix + "swing/set")
		OscillationModeSetpoint = payload_s
		print("received OscillationModeSetpoint = ", OscillationModeSetpoint)
		mqtt.publish(FeedbackTopicPrefix + "swing/get" , OscillationModeSetpoint)
		print("publishing immediately OscillationModeSetpoint")
	  
      elif topic == (topicprefix + "temperature/set")
	    #some offset trials , the feedback is the temperature without the offset
		
		TemperatureSetpoint = int(number((payload_s)))
        print("received TemperatureSetpoint = ", TemperatureSetpoint)
		
		if ACmode == "heat"
			TemperatureSetpoint = int(number((payload_s))) + TemperatureSetpointOffset
			print("heating mode, applying offset of :" , TemperatureSetpointOffset , "°C")
		end
		
		mqtt.publish(FeedbackTopicPrefix + "Actualsetpoint/get" , payload_s)
		print("publishing immediately TemperatureSetpoint")
	  
	  #used for debugging over mqtt
	  elif topic == "testsclim/payloadfromclim"
	  incomingpayload = payload_b
	  print("incomingpayload" ,incomingpayload)
	  print("type de payload = ", type(incomingpayload))
	  GetFrametype(incomingpayload)
	  
	  return true
	  end
	  #print("topic", topic)
	  #print("forging payload")
	  var frametosend = forgepayload(ACmode,FanSpeedSetpoint,OscillationModeSetpoint,TemperatureSetpoint)
	  print("sending frame to mqtt for debug: ", frametosend)
	  mqtt.publish("testsclim/rawpayload" , frametosend)
	  print("sending frame to AC unit: ", frametosend)
	  ser.write(frametosend)
	  return true
	end
	
	mqtt.subscribe(topicprefix + "mode/set",f)
	mqtt.subscribe(topicprefix + "fan/set",f)
	mqtt.subscribe(topicprefix + "swing/set",f)
	mqtt.subscribe(topicprefix + "temperature/set",f)
	mqtt.subscribe("testsclim/payloadfromclim",f)
	



def getfromserial()
	var avail = ser.available()
	if avail != 0
	    var msg = ser.read()
	    ser.flush()
	    if msg[0..1] == bytes("7A7A") && avail == msg.get(4,1)
			#print("buffer filled with :", avail , " bytes")
			#print ("message length :", msg.get(4,1))
			print("message from AC :", msg.tostring(60))
		
		elif msg[0..1] == bytes("7A7A") && avail > msg.get(4,1)
			#print ("buffer is bigger than frame, cutting frame")
			var msg2 = msg[msg.get(4,1)..size(msg)-1]
			msg = msg[0..msg.get(4,1)-1]
			print("message from AC :", msg.tostring(60))
			print("remaining msg   :", msg2.tostring(60)) #toto , implement a buffer of frames.
			#print("calling publishfeedback")
			PublishFeedback(msg)
		end	
	else 
	#	print ("nothing in the buffer")
	end
end

def loopme()
  getfromserial()
  tasmota.set_timer(200, loopme, 1)
end
loopme()






