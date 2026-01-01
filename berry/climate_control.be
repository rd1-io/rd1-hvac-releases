# Climate Control - automatic AC and Humidifier management
# Cooling: Power5 (Cool) ON/OFF based on indoor temperature vs target
# Humidity: Power6 (Humidifier) ON/OFF based on indoor humidity vs target

class ClimateController
  # Cooling settings
  static var TEMP_HYSTERESIS = 0.5  # Temperature hysteresis in °C
  # Humidity settings
  static var HUMIDITY_HYSTERESIS = 3  # Humidity hysteresis in %
  static var LCD_ADDR = 23
  static var HUMIDITY_REG = 113
  # Common settings
  static var CHECK_INTERVAL_MS = 5000  # Check every 5 seconds
  
  var cooling_on
  var humidifier_on
  var target_humidity
  var last_humidity_read_ms

  def init()
    self.cooling_on = false
    self.humidifier_on = false
    self.target_humidity = 50  # Default 50%
    self.last_humidity_read_ms = 0
    tasmota.add_driver(self)
    tasmota.set_timer(self.CHECK_INTERVAL_MS, /-> self.check_timer(), "climate_check")
    # Read target humidity from LCD
    tasmota.set_timer(5000, /-> self.read_humidity_target(), "humidity_read")
  end

  def check_timer()
    self.evaluate_cooling()
    self.evaluate_humidity()
    tasmota.set_timer(self.CHECK_INTERVAL_MS, /-> self.check_timer(), "climate_check")
  end

  def read_humidity_target()
    # Read target humidity from LCD via Modbus
    global.mb(self.LCD_ADDR, 3, self.HUMIDITY_REG, 1, nil, "clim:hum", false)
    tasmota.set_timer(30000, /-> self.read_humidity_target(), "humidity_read")
  end

  def on_humidity_target_read(val)
    if val >= 30 && val <= 80
      self.target_humidity = val
      self.last_humidity_read_ms = tasmota.millis()
    end
  end

  def is_fan_running()
    var fan_running = false
    try
      fan_running = global.fan_ctrl != nil && global.fan_ctrl.power_level > 0
    except ..
    end
    return fan_running
  end

  # ========== COOLING CONTROL ==========
  def evaluate_cooling()
    # If fan is not running, turn off cooling
    if !self.is_fan_running()
      if self.cooling_on
        self.set_cooling(false)
      end
      return
    end

    # Get current and target temperatures
    var current_t = nil
    var target_t = nil
    try
      current_t = global.lcd_presets.indoor_t
      target_t = global.lcd_presets.lcd_target_c
    except ..
    end

    # Safety: don't operate without valid temperature data
    if current_t == nil || target_t == nil
      return
    end

    # Cooling logic with hysteresis
    if current_t > target_t
      # Temperature above target - turn on cooling
      if !self.cooling_on
        self.set_cooling(true)
      end
    elif current_t <= target_t - self.TEMP_HYSTERESIS
      # Temperature below target minus hysteresis - turn off cooling
      if self.cooling_on
        self.set_cooling(false)
      end
    end
    # If between target-hysteresis and target, keep current state
  end

  def set_cooling(on)
    self.cooling_on = on
    tasmota.cmd(on ? "Power5 ON" : "Power5 OFF")
  end

  # ========== HUMIDITY CONTROL ==========
  def evaluate_humidity()
    # If fan is not running, turn off humidifier
    if !self.is_fan_running()
      if self.humidifier_on
        self.set_humidifier(false)
      end
      return
    end

    # Get current humidity from indoor sensor
    var current_h = nil
    try
      current_h = global.lcd_presets.indoor_h
    except ..
    end

    # Safety: don't operate without valid humidity data
    if current_h == nil
      return
    end

    # Humidifier logic with hysteresis
    # Turn ON when humidity is below target
    # Turn OFF when humidity is above target + hysteresis
    if current_h < self.target_humidity
      # Humidity below target - turn on humidifier
      if !self.humidifier_on
        self.set_humidifier(true)
      end
    elif current_h >= self.target_humidity + self.HUMIDITY_HYSTERESIS
      # Humidity above target plus hysteresis - turn off humidifier
      if self.humidifier_on
        self.set_humidifier(false)
      end
    end
    # If between target and target+hysteresis, keep current state
  end

  def set_humidifier(on)
    self.humidifier_on = on
    tasmota.cmd(on ? "Power6 ON" : "Power6 OFF")
  end

end

var climate_ctrl = ClimateController()
global.climate_ctrl = climate_ctrl

# Handle Modbus response for humidity target reading
tasmota.add_rule("ModBusReceived", def(value, trigger)
  if value == nil return end
  var dev = value['DeviceAddress']
  var fc = value['FunctionCode']
  var sa = value['StartAddress']
  if dev == 23 && fc == 3 && sa == 113
    var vals = nil
    try vals = value['Values'] except .. return end
    if vals != nil && size(vals) > 0
      climate_ctrl.on_humidity_target_read(int(vals[0]))
    end
  end
end)

