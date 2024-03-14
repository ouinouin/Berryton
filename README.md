# Berryton

Drive your airton AC unit from mqtt with an ESP32 module flashed with tasmota and this berry script

discussion here : 

https://github.com/arendst/Tasmota/discussions/17328
other solutions to drive the ac unit cooked by pingus will soon appear.

the purpose is to be able to drive the airton units (that are skyworth rebranded units) with an esp32 hooked to the serial port of the A/C unit.

the functionalities targeted for now are : 

- Setting the mode (Fan, dry , heat etc etc)
- Setting the fan speed (low medium high etc etc)
- Setting the louvres Height or oscillation
- Setting an external temperature source from mqtt and letting the unit regulate on itself by the help of an hysteresis thermostat function.

As not being a coder (this is my first published project), the code quality is likely to be poor , but the initial functionalities are working.

the initial functionality is working, while first running the script, wait 1 to 2 minutes for the script to recover the ac unit status to give correct feedback on mqtt.

i run this script with a M5stack atom ESP32 , mind that you need a bidirectional level shifter since the signals sent by the AC unit is in 5V.
there is a lot of discussions on the internet to know if ESP32 is or is not 5V tolerant. For now i run without level shifter and it still works after 1 year.


comments and contributions are welcome.


modbus crc snippet from  https://github.com/peepshow-21/ns-flash/blob/master/berry/nxpanel.be

## Regulation

two modes are actually available, one letting just the AC unit itself regulating on its own internal sensor (poor results) and one relying on an hysteresis thermostat coded in the berry script

in heat mode, you have to mind about using the remote control, as the remote will backfeed a value to the system, the berry code will then substract the offset value to the value cyclically retrieved from the AC unit and feed it to MQTT.

### offset mode

    var internalThermostat = 0
In heating mode an offset is implemented (TemperatureSetpointOffset). this offset is meant to be transparent from the homeassistant point of view.

The offset is just here to ensure a correct regulation while you regulate from an external thermostat, since the AC unit temperature sensor is sensing a much higher temperature at 2m height + its enclosed inside the ac unit.
The offset is added to the setpoint you send to the unit , then when reading the feedback from the AC unit, its substracted, to give a correct feedback to homeassistant.

The default offset is 8°C which seems to work well for a 30 m2 room.
bigger rooms might require a higher offset.

You have to make your experience to see what offset to be given for a maximum temperature stability on your room.

### hysteresis mode

    var internalThermostat = 1
    var externaltemptopic = "nodered/temp-salon"

In hysteresis mode (only tested in heating mode yet) , the unit will set  a temperature higher than your setpoint (+8°C by default). the script is subscribing to your temperature sensor topic : externaltemptopic , and then does the delta between the setpoint and the external temperature value : "**ActualTemp - Setpoint**" , if this result is > 0,3 °C , the unit will switch to a low temperature setpoint (by default 17°C) .

## Home assistant config

Associated homeassistant configuration to append in your configuration.yaml of homeassistant

note that the thermostat topic is coming from elsewhere

```
    - name: NewAirton
      unique_id: climate.NewAirton
      max_temp: 31.0
      min_temp: 16.0
      modes:
        - "auto"
        - "off"
        - "cool"
        - "heat"
        - "dry"
        - "fan_only"
      swing_modes:
        - "on"
        - "off"
        - "low"
        - "medium-low"
        - "medium"
        - "medium-high"
        - "high"
      fan_modes:
        - "turbo"
        - "high"
        - "medium-high"
        - "medium"
        - "low-medium"
        - "low"
        - "quiet"
        - "auto"
      #initial: 21
      current_temperature_topic : "nodered/temp-salon"
      power_command_topic: "cmnd/Newclim/power/set"
      mode_command_topic: "cmnd/Newclim/mode/set"
      temperature_command_topic: "cmnd/Newclim/temperature/set"
      fan_mode_command_topic: "cmnd/Newclim/fan/set"
      swing_mode_command_topic: "cmnd/Newclim/swing/set"
      
      fan_mode_state_topic: "tele/Newclim/fan/get"
      swing_mode_state_topic: "tele/Newclim/swing/get"
      mode_state_topic: "tele/Newclim/mode/get"
      temperature_state_topic: "tele/Newclim/Actualsetpoint/get"
      precision: 0.1

```

## Harware and connections : 
I choose some ESP32 from M5stack , the atom series are nice with a small form factor, I use the atom Lite, but the atom S3 is nice too.
all the ESP32 series should normally do the job despite having some stabilities issues withe ESP32-S2. buy an S3 if you can afford it.

https://shop.m5stack.com/products/atoms3-lite-esp32s3-dev-kit
https://shop.m5stack.com/products/atom-lite-esp32-development-kit

The connector on the AC unit is a JST SM to my knowledge , the pin spacing is 2.5mm , i could fit on the AC connector  a female 4 pins jst XH connector.
the pinout of the connector, (connector of AC unit , facing the pins from left to right, key of the connector up.)
on the ATOM side, there is a grove connector, i cut the one provided with the unit and then did solder the wires of a JST XH provided with 10cm of wire.

```
1 : Yellow              > +12vdc
2 : green               > AC unit RX (ESP32 TX, GPIO26 for ATOM LITE)
3 : Grey (or purple ? ) > AC unit TX (ESP32 RX, GPIO32 for ATOM LITE)
4 : Black               > GND
``` 
As the AC unit distributes some 12VDC , you ll have to solder a small DC DC converter , i choose an adjustable one. ideally it should be able to deliver 5V@1A.

I choosed to not put level shifters, despite not being advisable , the level of the serial port of the AC unit is 5VDC , and the pins of an ESP32 are 3.3V , there are a lot of debates amongst the internet to know if we can consider ESP32 as 5V tolerant, as per datasheet it it not, as per my experience, it is 5V tolerant. feel free to do things properly and add a bidirectionnal level shifter.

[here some pics of my setup](ressources/pictures)
mind that on the pictures the colors on my extension are not the same on both ends of the connectors since i soldered wires in the middle.

## Installing Tasmota
You dont need a specific version of tasmota to run the software, just install tasmota as per recommended documentation, then upload the berry files through the file manager , see : https://tasmota.github.io/docs/UFS/

The berry language on tasmota is looking for autoexec.be at startup, if present it will execute it. the autoexec.be then just loads Berryton.be
If you own some hardware with sdcard support, you can also load berryton by changing the autoexec.be , replace 
```
load("Berryton.be")
```
by 
```
load("sd/Berryton.be")
```

## TODO


  - [ ] Implement the get and set functions as tasmota functions to be able to use them in tasmota and out of tasmota through HTTP.
  - [ ] Let berryton be a berry object.
  - [ ] Document the hardware side of berryton (the bad way with no level shifters and the good way with level shifters).
  - [ ] Fix turbo mode and improve code for all the set commands.
  - [ ] Create the ack frame for the wifi LED of AC unit not to blink anymore.
  - [ ] Use BLE to interact with BLE temperature sensors supported by tasmota.
  - [ ] Publish the mqtt autodiscovery message for Homeassistant to be able to discover the AC unit.
  - [ ] Create some web buttons and informations on the web interface of tasmota.
  - [ ] Publish the spreadsheet of the protocol made with pingus.




