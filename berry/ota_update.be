# OTA Update Script for Berry files
# Downloads all .be files from GitHub releases repository

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
  end
  wc.close()
  return nil
end

# Download a single file from GitHub
def ota_download_file(name)
  var url = OTA_BASE_URL + name
  print("OTA: Downloading", name)
  var wc = webclient()
  wc.begin(url)
  var code = wc.GET()
  if code == 200
    var content = wc.get_string()
    var f = open("/" + name, "w")
    f.write(content)
    f.close()
    print("OTA: OK -", name, "(", size(content), "bytes)")
    wc.close()
    return true
  else
    print("OTA: FAILED -", name, "HTTP", code)
    wc.close()
    return false
  end
end

# Download all Berry files and restart
def ota_start_update()
  print("OTA: Starting Berry files update...")
  print("OTA: Base URL:", OTA_BASE_URL)
  
  # First check version
  var version_info = ota_check_update()
  if version_info == nil
    print("OTA: No update needed or cannot get version info")
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
    tasmota.delay(100)
  end
  
  print("OTA: Download complete. Success:", success, "Failed:", failed)
  
  if failed == 0
    ota_save_version(new_version)
    print("OTA: All files updated to version", new_version)
    print("OTA: Restarting in 2 seconds...")
    tasmota.set_timer(2000, /-> tasmota.cmd("Restart 1"))
    return true
  else
    print("OTA: Some files failed to download. Not restarting.")
    return false
  end
end

# Force update (skip version check)
def ota_force_update()
  print("OTA: Force updating Berry files...")
  print("OTA: Base URL:", OTA_BASE_URL)
  
  var success = 0
  var failed = 0
  
  for file : OTA_FILES
    if ota_download_file(file)
      success += 1
    else
      failed += 1
    end
    tasmota.delay(100)
  end
  
  print("OTA: Download complete. Success:", success, "Failed:", failed)
  
  if failed == 0
    # Try to get and save new version
    var wc = webclient()
    wc.begin(OTA_VERSION_URL)
    if wc.GET() == 200
      import json
      var info = json.load(wc.get_string())
      if info != nil
        ota_save_version(int(info["berry"]))
      end
    end
    wc.close()
    print("OTA: Restarting in 2 seconds...")
    tasmota.set_timer(2000, /-> tasmota.cmd("Restart 1"))
    return true
  else
    print("OTA: Some files failed to download. Not restarting.")
    return false
  end
end

# Export functions for external call
global.ota_start_update = ota_start_update
global.ota_force_update = ota_force_update
global.ota_check_update = ota_check_update
global.ota_get_current_version = ota_get_current_version

print("OTA: Update module loaded. Version:", ota_get_current_version())
