import string
import persist

# Filter Wear Tracking Module
# Tracks accumulated filter wear based on fan motor power
# 
# Algorithm:
# - Base lifetime: 6 months at 100% load (15,552,000 seconds)
# - Each second: filter_wear += max(supply_pct, exhaust_pct)
# - Wear percent = filter_wear / 15,552,000
# - At 50% load: 12 months lifetime
# - At 100% load: 6 months lifetime

class FilterWear
  static var MAX_WEAR_SECONDS = 15552000  # 6 months * 30 days * 24 hours * 60 min * 60 sec
  static var SAVE_INTERVAL_MS = 300000    # Save every 5 minutes
  var filter_wear        # accumulated wear (seconds * percent)
  var last_save_ms       # last save timestamp
  var promille           # current wear in promille (0-1000+)

  def init()
    persist.load()
    self.filter_wear = persist.find('filter_wear', 0)
    self.last_save_ms = tasmota.millis()
    self.promille = int(self.filter_wear / 1555200)
    tasmota.add_driver(self)
  end

  def every_second()
    # Get current fan power levels
    var supply_pct = 0
    var exhaust_pct = 0
    try
      supply_pct = global.fan_ctrl.supply_pct
      exhaust_pct = global.fan_ctrl.exhaust_pct
    except ..
    end

    # Use maximum of the two motors
    var max_pct = supply_pct > exhaust_pct ? supply_pct : exhaust_pct

    # Accumulate wear (only if fans are running)
    if max_pct > 0
      self.filter_wear += max_pct
    end

    # Update promille
    self.promille = int(self.filter_wear / 1555200)

    # Save periodically (every 5 minutes) to preserve flash
    var now = tasmota.millis()
    if now - self.last_save_ms > self.SAVE_INTERVAL_MS
      self.save()
      self.last_save_ms = now
    end
  end

  def save()
    persist.filter_wear = self.filter_wear
    persist.save()
  end

  # Returns wear percentage (0-100+)
  def get_wear_percent()
    return self.filter_wear / 15552000.0
  end

  def reset()
    self.filter_wear = 0
    self.promille = 0
    persist.filter_wear = 0
    persist.save()
  end

end

var filter_wear = FilterWear()
global.filter_wear = filter_wear

tasmota.add_cmd('FilterWearReset', def(cmd, idx, payload)
  filter_wear.reset()
  tasmota.resp_cmnd('{"FilterWear":"Reset"}')
end)

