import string

class ExhaustModeController
  static var DI_ADDR = 140
  static var MODE_REG = 1
  var active
  var last_poll_ms

  def init()
    self.active = false
    self.last_poll_ms = 0
    tasmota.add_driver(self)
    tasmota.set_timer(5000, /-> self.start_poll())
  end

  def start_poll()
    self.poll_mode_register()
    tasmota.set_timer(10007, /-> self.start_poll(), "exhaust_mode_poll")
  end

  def poll_mode_register()
    var now = tasmota.millis()
    if now - self.last_poll_ms < 1000 return end
    self.last_poll_ms = now
    global.mb(self.DI_ADDR, 4, self.MODE_REG, 1, nil, "exhaust:mode", false)
  end

  def on_mode_read(val)
    var was_active = self.active
    self.active = (val != nil && int(val) != 0)
    if self.active != was_active
      try
        if global.fan_ctrl != nil && global.fan_ctrl.power_level > 0 && global.fan_ctrl.valve_open
          global.fan_ctrl.set_both(global.fan_ctrl.power_level)
        end
      except .. end
    end
  end

  def is_active()
    return self.active
  end

end

var exhaust_mode = ExhaustModeController()
global.exhaust_mode = exhaust_mode

tasmota.add_rule("ModBusReceived", def(value, trigger)
  if value == nil return end
  var dev = value['DeviceAddress']
  var fc = value['FunctionCode']
  var sa = value['StartAddress']
  var vals = nil
  try vals = value['Values'] except .. return end
  if dev == 140 && fc == 4 && sa == 1
    if vals != nil && size(vals) > 0
      exhaust_mode.on_mode_read(vals[0])
    end
  end
end)

