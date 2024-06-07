# Berryton

Drive your airton AC unit from mqtt with an ESP32 module flashed with tasmota and this berry script

discussion here : 

https://github.com/arendst/Tasmota/discussions/17328
other solutions to drive the ac unit cooked by pingus will soon appear.

the purpose is to be able to drive the airton units (that are most likely tcl clones) with an esp32 hooked to the serial port of the A/C unit.

the functionalities targeted for now are : 

- Setting the mode (Fan, dry , heat etc etc)
- Setting the fan speed (low medium high etc etc
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

In this mode , the ESP32 takes care of the regulation, by using and hysteresis control , the hysteresis is set in the code by the variable "hyst"
this mode is active for both heat and cool modes.

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





