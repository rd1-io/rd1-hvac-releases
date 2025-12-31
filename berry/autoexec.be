# Berry autoexec - loads all modules at startup
# OTA module is loaded first to check for pending updates
# All loads wrapped in try/except to handle missing files during OTA

# Load OTA first - it will check if update is pending and continue if needed
try load("ota_update.be") except .. end

# Load all other modules (may be missing during OTA phase 2)
try load("co2_sensor.be") except .. end
try load("modbus_utils.be") except .. end
try load("relay_control.be") except .. end
try load("error_handler.be") except .. end
try load("exhaust_mode.be") except .. end
try load("fan_control.be") except .. end
try load("sht20_sensors.be") except .. end
try load("valve_shutter_bridge.be") except .. end
try load("filter_wear.be") except .. end
try load("lcd_bridge.be") except .. end
try load("cloud_logger.be") except .. end
