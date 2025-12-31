# OTA Update Script for Berry files
# Two-phase update: Phase 1 deletes files, Phase 2 downloads after restart
# This solves RAM limitation by having clean memory for downloads

import persist

# Global flag to pause background tasks during OTA
global.ota_in_progress = false

# Files to update (excluding autoexec.be and ota_update.be which are kept)
var OTA_FILES_TO_DOWNLOAD = [
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
  "cloud_logger.be",
  "exhaust_mode.be",
  "ota_update.be"
]

# Files to delete in Phase 1 (everything except autoexec.be and ota_update.be)
var OTA_FILES_TO_DELETE = [
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
  "cloud_logger.be",
  "exhaust_mode.be"
]

# Public releases repository URL
var OTA_BASE_URL = "https://raw.githubusercontent.com/rd1-io/rd1-hvac-releases/main/berry/"
var OTA_VERSION_URL = "https://raw.githubusercontent.com/rd1-io/rd1-hvac-releases/main/version.json"

# Get current installed version from persist
def ota_get_current_version()
  var ver = persist.find("berry_version")
  return ver != nil ? int(ver) : 0
end

# Save version to persist after successful update
def ota_save_version(ver)
  persist.berry_version = int(ver)
  persist.save()
  print("OTA: Saved version", ver)
end

# Check for available updates (returns version number or nil)
def ota_check_update()
  print("OTA: Checking for updates...")
  tasmota.gc()
  var wc = webclient()
  wc.set_useragent("Tasmota/OTA")
  wc.set_follow_redirects(true)
  wc.begin(OTA_VERSION_URL)
  var code = wc.GET()
  if code == 200
    var json_str = wc.get_string()
    wc.close()
    wc = nil
    tasmota.gc()
    import json
    var info = json.load(json_str)
    json_str = nil
    if info != nil
      var available = int(info["berry"])
      var current = ota_get_current_version()
      print("OTA: Available:", available, "Current:", current)
      if available > current
        print("OTA: Update available!")
        return available
      else
        print("OTA: Already up to date")
        return nil
      end
    end
  else
    print("OTA: Failed to check version, HTTP", code)
  end
  try wc.close() except .. end
  return nil
end

# Delete a file if it exists
def ota_delete_file(name)
  try
    import path
    if path.exists("/" + name)
      path.remove("/" + name)
      print("OTA: Deleted", name)
    end
  except .. as e
    print("OTA: Cannot delete", name, e)
  end
end

# Download a single file from GitHub
def ota_download_file(name)
  tasmota.gc()
  tasmota.delay(200)
  
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
    wc = nil
    tasmota.gc()
    
    if content == nil || size(content) < 10
      print("OTA: FAILED -", name, "empty or too small")
      content = nil
      tasmota.gc()
      return false
    end
    
    var f = open("/" + name, "w")
    f.write(content)
    f.close()
    var sz = size(content)
    content = nil
    tasmota.gc()
    print("OTA: OK -", name, "(", sz, "bytes)")
    return true
  else
    print("OTA: FAILED -", name, "HTTP", code)
    try wc.close() except .. end
    tasmota.gc()
    return false
  end
end

# ============================================
# PHASE 1: Delete files and set pending flag
# ============================================
def ota_start_update()
  print("OTA: === PHASE 1: Preparing update ===")
  global.ota_in_progress = true
  
  # Check for available updates first
  var new_version = ota_check_update()
  if new_version == nil
    print("OTA: No update available")
    global.ota_in_progress = false
    return false
  end
  
  print("OTA: Will update to version", new_version)
  
  # Delete all files except autoexec.be and ota_update.be
  print("OTA: Deleting old files...")
  for file : OTA_FILES_TO_DELETE
    ota_delete_file(file)
  end
  
  # Set pending flag with target version
  persist.ota_pending = new_version
  persist.save()
  print("OTA: Set ota_pending =", new_version)
  
  # Restart to free memory
  print("OTA: Restarting for Phase 2...")
  tasmota.set_timer(1000, /-> tasmota.cmd("Restart 1"))
  return true
end

# ============================================
# PHASE 2: Download files (runs after restart)
# ============================================
def ota_continue_update()
  var pending = persist.find("ota_pending")
  if pending == nil
    return false  # No pending update
  end
  
  print("OTA: === PHASE 2: Downloading files ===")
  print("OTA: Target version:", pending)
  global.ota_in_progress = true
  
  var success = 0
  var failed = 0
  
  for file : OTA_FILES_TO_DOWNLOAD
    if ota_download_file(file)
      success += 1
    else
      failed += 1
    end
    tasmota.delay(500)
  end
  
  print("OTA: Download complete. Success:", success, "Failed:", failed)
  
  # Clear pending flag
  persist.ota_pending = nil
  persist.save()
  
  if failed == 0
    ota_save_version(int(pending))
    print("OTA: === UPDATE SUCCESSFUL ===")
    print("OTA: Restarting with new firmware...")
    tasmota.set_timer(2000, /-> tasmota.cmd("Restart 1"))
    return true
  else
    print("OTA: === UPDATE FAILED ===")
    print("OTA: Some files failed. System may be incomplete.")
    print("OTA: Try running update again or restore manually.")
    tasmota.set_timer(2000, /-> tasmota.cmd("Restart 1"))
    return false
  end
end

# Force update (skip version check)
def ota_force_update()
  print("OTA: === FORCE UPDATE ===")
  global.ota_in_progress = true
  
  # Get latest version number
  tasmota.gc()
  var new_version = 0
  var wc = webclient()
  wc.set_useragent("Tasmota/OTA")
  wc.set_follow_redirects(true)
  wc.begin(OTA_VERSION_URL)
  if wc.GET() == 200
    import json
    var info = json.load(wc.get_string())
    if info != nil
      new_version = int(info["berry"])
    end
  end
  wc.close()
  wc = nil
  tasmota.gc()
  
  if new_version == 0
    new_version = ota_get_current_version() + 1
  end
  
  # Delete all files except autoexec.be and ota_update.be
  print("OTA: Deleting old files...")
  for file : OTA_FILES_TO_DELETE
    ota_delete_file(file)
  end
  
  # Set pending flag
  persist.ota_pending = new_version
  persist.save()
  print("OTA: Set ota_pending =", new_version)
  
  # Restart for Phase 2
  print("OTA: Restarting for Phase 2...")
  tasmota.set_timer(1000, /-> tasmota.cmd("Restart 1"))
  return true
end

# Export functions for external call
global.ota_start_update = ota_start_update
global.ota_force_update = ota_force_update
global.ota_check_update = ota_check_update
global.ota_get_current_version = ota_get_current_version
global.ota_continue_update = ota_continue_update

# ============================================
# AUTO-CHECK: Continue Phase 2 if pending
# ============================================
print("OTA: Module loaded. Version:", ota_get_current_version())

if persist.find("ota_pending") != nil
  print("OTA: Pending update detected!")
  # Delay slightly to let system stabilize
  tasmota.set_timer(3000, ota_continue_update)
end
