# OTA Update Script for Berry files
# Downloads all .be files from GitHub releases repository

# Global flag to pause background tasks during OTA
global.ota_in_progress = false

var OTA_FILES = [
  "autoexec.be",
  "preinit.be", 
  "lcd_bridge.be",
  "fan_control.be",
  "error_handler.be",
  "co2_sensor.be",
  "sht20_sensors.be",
  "modbus_utils.be",
  "relay_control.be",
  "valve_shutter_bridge.be",
  "filter_wear.be",
  "ota_update.be"
]

# Public releases repository URL
var OTA_BASE_URL = "https://raw.githubusercontent.com/rd1-io/rd1-hvac-releases/main/berry/"
var OTA_VERSION_URL = "https://raw.githubusercontent.com/rd1-io/rd1-hvac-releases/main/version.json"

# Get current installed version from persist
def ota_get_current_version()
  import persist
  var ver = persist.find("berry_version")
  return ver != nil ? int(ver) : 0
end

# Save version to persist after successful update
def ota_save_version(ver)
  import persist
  persist.berry_version = int(ver)
  persist.save()
  print("OTA: Saved version", ver)
end

# Check for available updates (returns version info or nil)
def ota_check_update()
  print("OTA: Checking for updates...")
  var wc = webclient()
  wc.set_useragent("Tasmota/OTA")
  wc.set_follow_redirects(true)
  wc.begin(OTA_VERSION_URL)
  var code = wc.GET()
  if code == 200
    var json_str = wc.get_string()
    wc.close()
    import json
    var info = json.load(json_str)
    if info != nil
      var available = int(info["berry"])
      var current = ota_get_current_version()
      print("OTA: Available:", available, "Current:", current)
      if available > current
        print("OTA: Update available!")
        return info
      else
        print("OTA: Already up to date")
        return nil
      end
    end
  else
    print("OTA: Failed to check version, HTTP", code)
    if code < 0
      print("OTA: Network error (negative code)")
    elif code == 1
      print("OTA: Connection/TLS error - check internet/SSL")
    end
  end
  wc.close()
  return nil
end

# Download a single file from GitHub
def ota_download_file(name)
  # Force garbage collection before each download to free memory
  tasmota.gc()
  
  var url = OTA_BASE_URL + name
  print("OTA: Downloading", name)
  var wc = webclient()
  wc.set_useragent("Tasmota/OTA")
  wc.set_follow_redirects(true)
  wc.begin(url)
  var code = wc.GET()
  if code == 200
    var content = wc.get_string()
    wc.close()
    wc = nil  # Release webclient
    
    # Check for valid content
    if content == nil || size(content) < 10
      print("OTA: FAILED -", name, "empty or too small:", size(content), "bytes")
      return false
    end
    
    var f = open("/" + name, "w")
    f.write(content)
    f.close()
    var sz = size(content)
    content = nil  # Release content buffer
    print("OTA: OK -", name, "(", sz, "bytes)")
    tasmota.gc()  # Clean up after write
    return true
  else
    print("OTA: FAILED -", name, "HTTP", code)
    wc.close()
    wc = nil
    tasmota.gc()
    return false
  end
end

# Stop all background activity - timers and rules
# Berry doesn't have API to list all timers/rules, so we use known names
# tasmota.remove_timer/remove_rule silently ignores non-existent items
def ota_stop_background()
  # Known timer IDs used in our codebase
  var timers = [
    "lcd_status", "lcd_batch", "lcd_ds18",
    "cloud_periodic", "relay_poll", "co2_auto_read",
    "sht_ot", "sht_oh", "sht_it", "sht_ih",
    "exhaust_mode_poll", "err_mao4", "err_di", "err_lcd",
    "fan_shutdown_retry", "fan_shutdown_complete", "fan_verify"
  ]
  
  # Known rule triggers used in our codebase  
  var rules = [
    "ModBusReceived", "RESULT", "Tele-JSON",
    "Shutter1#Target", "Matter#Commissioning"
  ]
  
  # Remove all timers
  for t : timers
    try tasmota.remove_timer(t) except .. end
  end
  
  # Remove all rules
  for r : rules
    try tasmota.remove_rule(r) except .. end
  end
  
  # Remove Power state rules (1-9)
  for i : 1 .. 9
    try tasmota.remove_rule("Power" + str(i) + "#State") except .. end
  end
  
  print("OTA: Background stopped (timers + rules)")
end

# Download all Berry files and restart
def ota_start_update()
  print("OTA: Starting Berry files update...")
  print("OTA: Base URL:", OTA_BASE_URL)
  
  # Pause background tasks
  global.ota_in_progress = true
  ota_stop_background()
  
  # First check version
  var version_info = ota_check_update()
  if version_info == nil
    print("OTA: No update needed or cannot get version info")
    global.ota_in_progress = false
    return false
  end
  
  var new_version = int(version_info["berry"])
  var success = 0
  var failed = 0
  
  for file : OTA_FILES
    if ota_download_file(file)
      success += 1
    else
      failed += 1
    end
    tasmota.gc()  # Force garbage collection
    tasmota.delay(1000)  # Longer delay for memory cleanup
  end
  
  print("OTA: Download complete. Success:", success, "Failed:", failed)
  
  if failed == 0
    ota_save_version(new_version)
    print("OTA: All files updated to version", new_version)
    # Send success status (2) to LCD
    try global.lcd_presets.write_u16(400, 2) except .. end
    print("OTA: Restarting in 2 seconds...")
    tasmota.set_timer(2000, /-> tasmota.cmd("Restart 1"))
    return true
  else
    print("OTA: Some files failed to download.")
    # Send error status (3) to LCD
    try global.lcd_presets.write_u16(400, 3) except .. end
    # Must restart to restore rules/timers that were removed
    print("OTA: Restarting to restore system state...")
    tasmota.set_timer(2000, /-> tasmota.cmd("Restart 1"))
    return false
  end
end

# Force update (skip version check)
def ota_force_update()
  print("OTA: Force updating Berry files...")
  print("OTA: Base URL:", OTA_BASE_URL)
  
  # Pause background tasks
  global.ota_in_progress = true
  ota_stop_background()
  
  var success = 0
  var failed = 0
  
  for file : OTA_FILES
    if ota_download_file(file)
      success += 1
    else
      failed += 1
    end
    tasmota.gc()  # Force garbage collection
    tasmota.delay(1000)  # Longer delay for memory cleanup
  end
  
  print("OTA: Download complete. Success:", success, "Failed:", failed)
  
  if failed == 0
    # Try to get and save new version
    var wc = webclient()
    wc.set_useragent("Tasmota/OTA")
    wc.set_follow_redirects(true)
    wc.begin(OTA_VERSION_URL)
    if wc.GET() == 200
      import json
      var info = json.load(wc.get_string())
      if info != nil
        ota_save_version(int(info["berry"]))
      end
    end
    wc.close()
    # Send success status (2) to LCD
    try global.lcd_presets.write_u16(400, 2) except .. end
    print("OTA: Restarting in 2 seconds...")
    tasmota.set_timer(2000, /-> tasmota.cmd("Restart 1"))
    return true
  else
    print("OTA: Some files failed to download.")
    # Send error status (3) to LCD
    try global.lcd_presets.write_u16(400, 3) except .. end
    # Must restart to restore rules/timers that were removed
    print("OTA: Restarting to restore system state...")
    tasmota.set_timer(2000, /-> tasmota.cmd("Restart 1"))
    return false
  end
end

# Export functions for external call
global.ota_start_update = ota_start_update
global.ota_force_update = ota_force_update
global.ota_check_update = ota_check_update
global.ota_get_current_version = ota_get_current_version

print("OTA: Update module loaded. Version:", ota_get_current_version())
