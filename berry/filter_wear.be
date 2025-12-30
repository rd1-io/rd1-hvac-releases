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
  var last_wear_sent     # last wear promille sent to LCD

  def init()
    persist.load()
    self.filter_wear = persist.find('filter_wear', 0)
    self.last_save_ms = tasmota.millis()
    self.last_wear_sent = nil
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

  # Returns wear in promille (0-1000+), where 1000 = 100%
  def get_wear_promille()
    # filter_wear * 1000 / (MAX_WEAR_SECONDS * 100)
    return int(self.filter_wear / 1555200)
  end

  # Returns wear percentage (0-100+)
  def get_wear_percent()
    # filter_wear / (MAX_WEAR_SECONDS * 100) * 100
    return self.filter_wear / 15552000.0
  end

  # Returns remaining lifetime in months (approximate)
  def get_remaining_months()
    var wear_pct = self.get_wear_percent()
    if wear_pct >= 100
      return 0.0
    end
    # At 50% average load, remaining = (100 - wear_pct) / 100 * 12 months
    # This is approximate assuming continued 50% average load
    return (100.0 - wear_pct) / 100.0 * 12.0
  end

  def reset()
    self.filter_wear = 0
    persist.filter_wear = 0
    persist.save()
    self.last_wear_sent = nil
  end

  def web_sensor()
    var pct = self.get_wear_percent()
    tasmota.web_send_decimal(string.format("{s}Износ фильтров{m}%.1f %%{e}", pct))
  end

  def json_append()
    var pct = self.get_wear_percent()
    var promille = self.get_wear_promille()
    tasmota.response_append(string.format(',"FilterWear":{"Percent":%.1f,"Promille":%d}', pct, promille))
  end
end

var filter_wear = FilterWear()
global.filter_wear = filter_wear

# Command: FilterWear - show current filter wear
tasmota.add_cmd('FilterWear', def(cmd, idx, payload)
  var pct = filter_wear.get_wear_percent()
  var promille = filter_wear.get_wear_promille()
  var remaining = filter_wear.get_remaining_months()
  tasmota.resp_cmnd(string.format('{"FilterWear":{"Percent":%.1f,"Promille":%d,"RemainingMonths":%.1f}}', pct, promille, remaining))
end)

# Command: FilterWearReset - reset filter wear counter
tasmota.add_cmd('FilterWearReset', def(cmd, idx, payload)
  filter_wear.reset()
  tasmota.resp_cmnd('{"FilterWear":"Reset"}')
end)



