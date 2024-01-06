# Berryton
Drive your airton AC unit from mqtt with an esp32 module flashed with tasmota and this berry script

discussion here : 

https://github.com/arendst/Tasmota/discussions/17328
other solutions to drive the ac unit cooked by pingus will soon appear.

the purpose is to be able to drive the airton units (that are most likely tcl clones) with an esp32 hooked to the serial port of the A/C unit.

the functionalities targeted for now are : 

- Setting the mode (Fan, dry , heat etc etc)
- Setting the fan speed (low medium high etc etc
- Setting the louvres Height or oscillation

As not being a coder (this is my first published project), the code quality is likely to be poor , but the initial functionalities are working.

the initial functionality is working, while first running the script, wait 1 to 2 minutes for the script to recover the ac unit status to give correct feedback on mqtt.

i run this script with a M5stack atom ESP32 , mind that you need a bidirectionnal level shifter since the signals sent by the AC unit is in 5V.
there is a lot of discussions on the internet to know if ESP32 is or isnot 5V tolerant. For now i run without level shifter and it still works after 1 year.


comments are welcome with pictures and data to see how poor is the regulation yet :-), feedback  might or might not come depending on my time.


modbus crc snippet from  https://github.com/peepshow-21/ns-flash/blob/master/berry/nxpanel.be

associated homeassistant configuration to append in your configuration.yaml of homeassistant
note that the thermostat topic is coming from elsewhere , in heating mode this could lead you to need to set an offset in the code (yet to be implemented).
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





