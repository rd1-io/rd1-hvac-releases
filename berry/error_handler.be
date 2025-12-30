import string

class ErrorHandler
  static var MAO4_ADDR = 109
  static var DI_ADDR = 140
  static var LCD_ADDR = 23
  static var MAO4_COUNTER_REG = 32
  static var SUPPLY_REG = 16
  static var EXHAUST_REG = 17
  static var DI_START_REG = 32
  static var DI_REG_COUNT = 6
  static var ERROR_REG = 200
  static var RESET_REG = 104
  static var PAUSE_RELEASE_REG = 108
  static var PAUSE_ACTIVATE_REG = 109
  static var ERR_PRESSURE = 0x01
  static var ERR_RECUPERATOR = 0x02
  static var ERR_FILTER_SUPPLY = 0x04
  static var ERR_FILTER_EXHAUST = 0x08
  static var ERR_PAUSE = 0x8000
  
  var error_mask, last_sent_mask, last_sync_ms
  var mao4_initial, mao4_current, mao4_init
  var error_set_ms, last_reset_ms
  var di_initial, di_current, di_init
  var pause_active, pause_set_ms
  var last_di_poll_ms

  def init()
    self.error_mask = 0
    self.last_sent_mask = -1
    self.last_sync_ms = 0
    self.mao4_initial = nil
    self.mao4_current = nil
    self.mao4_init = false
    self.error_set_ms = 0
    self.last_reset_ms = 0
    self.di_initial = [nil, nil, nil, nil, nil, nil]
    self.di_current = [nil, nil, nil, nil, nil, nil]
    self.di_init = [false, false, false, false, false, false]
    self.pause_active = false
    self.pause_set_ms = 0
    self.last_di_poll_ms = 0
    tasmota.add_driver(self)
    tasmota.set_timer(3000, /-> self.start_mao4_poll())
    tasmota.set_timer(4000, /-> self.start_di_poll())
    tasmota.set_timer(5000, /-> self.start_lcd_sync())
  end

  def start_mao4_poll()
    self.poll_mao4_counter()
    tasmota.set_timer(10007, /-> self.start_mao4_poll(), "err_mao4")
  end

  def start_di_poll()
    self.poll_di_batch()
    tasmota.set_timer(9973, /-> self.start_di_poll(), "err_di")
  end

  def start_lcd_sync()
    self.sync_lcd_periodic()
    tasmota.set_timer(59987, /-> self.start_lcd_sync(), "err_lcd")
  end


  def poll_mao4_counter()
    tasmota.cmd(string.format('MBGateCritical {"deviceaddress":%d,"functioncode":4,"startaddress":%d,"type":"uint16","count":1,"tag":"err:mao4","quiet":30,"retries":2}', self.MAO4_ADDR, self.MAO4_COUNTER_REG))
  end

  def poll_di_batch()
    var now = tasmota.millis()
    if now - self.last_di_poll_ms < 1000 return end
    self.last_di_poll_ms = now
    tasmota.cmd(string.format('MBGateCritical {"deviceaddress":%d,"functioncode":4,"startaddress":%d,"type":"uint16","count":%d,"tag":"err:di","quiet":30,"retries":2}', self.DI_ADDR, self.DI_START_REG, self.DI_REG_COUNT))
  end

  def emergency_fan_stop()
    tasmota.cmd(string.format('MBGateCritical {"deviceaddress":%d,"functioncode":16,"startaddress":%d,"type":"uint16","count":1,"values":[0],"tag":"err:emrg","quiet":30,"retries":3}', self.MAO4_ADDR, self.SUPPLY_REG))
    tasmota.set_timer(100, /-> tasmota.cmd(string.format('MBGateCritical {"deviceaddress":%d,"functioncode":16,"startaddress":%d,"type":"uint16","count":1,"values":[0],"tag":"err:emrg","quiet":30,"retries":3}', self.MAO4_ADDR, self.EXHAUST_REG)))
  end

  def restore_mao4_channels()
    tasmota.cmd(string.format('MBGate {"deviceaddress":%d,"functioncode":16,"startaddress":%d,"type":"uint16","count":1,"values":[0],"tag":"err:rst","quiet":30,"retries":2}', self.MAO4_ADDR, self.SUPPLY_REG))
    tasmota.set_timer(200, /-> tasmota.cmd(string.format('MBGate {"deviceaddress":%d,"functioncode":16,"startaddress":%d,"type":"uint16","count":1,"values":[0],"tag":"err:rst","quiet":30,"retries":2}', self.MAO4_ADDR, self.EXHAUST_REG)))
    tasmota.set_timer(400, /-> tasmota.cmd(string.format('MBGate {"deviceaddress":%d,"functioncode":5,"startaddress":%d,"type":"bit","count":1,"values":[1],"tag":"err:rst","quiet":30,"retries":2}', self.MAO4_ADDR, self.SUPPLY_REG)))
    tasmota.set_timer(600, /-> tasmota.cmd(string.format('MBGate {"deviceaddress":%d,"functioncode":5,"startaddress":%d,"type":"bit","count":1,"values":[1],"tag":"err:rst","quiet":30,"retries":2}', self.MAO4_ADDR, self.EXHAUST_REG)))
  end

  def on_mao4_counter(val)
    self.mao4_current = int(val)
    if !self.mao4_init
      self.mao4_initial = self.mao4_current
      self.mao4_init = true
      return
    end
    if self.mao4_current > 0 && self.mao4_current != self.mao4_initial
      if (self.error_mask & self.ERR_PRESSURE) == 0
        self.error_mask = self.error_mask | self.ERR_PRESSURE
        self.error_set_ms = tasmota.millis()
        print(string.format("[ERR] PRESSURE ERROR (MAO4)! counter=%d (was %d)", self.mao4_current, self.mao4_initial))
        self.emergency_fan_stop()
        self.sync_lcd(false)
      end
    end
  end

  def on_di_batch(vals)
    if vals == nil || size(vals) < 6 return end
    for i: 0 .. 5
      self.di_current[i] = int(vals[i])
      if !self.di_init[i]
        self.di_initial[i] = self.di_current[i]
        self.di_init[i] = true
      end
    end
    if self.di_init[0] && self.di_current[0] != self.di_initial[0]
      self.di_initial[0] = self.di_current[0]
      self.toggle_pause()
    end
    if self.di_init[3] && self.di_current[3] != self.di_initial[3]
      if (self.error_mask & self.ERR_FILTER_SUPPLY) == 0
        self.error_mask = self.error_mask | self.ERR_FILTER_SUPPLY
        self.error_set_ms = tasmota.millis()
        print(string.format("[ERR] FILTER SUPPLY DP! counter=%d (was %d)", self.di_current[3], self.di_initial[3]))
        self.emergency_fan_stop()
        self.sync_lcd(false)
      end
    end
    if self.di_init[4] && self.di_current[4] != self.di_initial[4]
      if (self.error_mask & self.ERR_FILTER_EXHAUST) == 0
        self.error_mask = self.error_mask | self.ERR_FILTER_EXHAUST
        self.error_set_ms = tasmota.millis()
        print(string.format("[ERR] FILTER EXHAUST DP! counter=%d (was %d)", self.di_current[4], self.di_initial[4]))
        self.emergency_fan_stop()
        self.sync_lcd(false)
      end
    end
    if self.di_init[5] && self.di_current[5] != self.di_initial[5]
      if (self.error_mask & self.ERR_RECUPERATOR) == 0
        self.error_mask = self.error_mask | self.ERR_RECUPERATOR
        self.error_set_ms = tasmota.millis()
        print(string.format("[ERR] RECUPERATOR DP! counter=%d (was %d)", self.di_current[5], self.di_initial[5]))
        self.emergency_fan_stop()
        self.sync_lcd(false)
      end
    end
  end

  def toggle_pause()
    var now = tasmota.millis()
    if now - self.pause_set_ms < 10000 return end
    if self.pause_active
      self.release_pause()
    else
      self.activate_pause()
    end
  end

  def activate_pause()
    if self.pause_active return end
    var now = tasmota.millis()
    if now - self.pause_set_ms < 10000 return end
    self.pause_active = true
    self.pause_set_ms = now
    self.error_mask = self.error_mask | self.ERR_PAUSE
    print("[PAUSE] System paused by external button")
    try global.fan_ctrl.set_power_level(0) except .. 
      tasmota.cmd("VentPowerLevel 0")
    end
    self.sync_lcd(false)
  end

  def release_pause()
    if !self.pause_active return end
    var now = tasmota.millis()
    if now - self.pause_set_ms < 10000 return end
    self.pause_active = false
    self.pause_set_ms = now
    self.error_mask = self.error_mask & (0xFFFF ^ self.ERR_PAUSE)
    print("[PAUSE] System resumed")
    tasmota.cmd(string.format('MBGate {"deviceaddress":%d,"functioncode":16,"startaddress":%d,"type":"uint16","count":1,"values":[0],"tag":"err:pclr","quiet":60,"retries":2}', self.LCD_ADDR, self.PAUSE_RELEASE_REG))
    self.sync_lcd(false)
  end

  def on_pause_control(release_val, activate_val)
    var release_req = release_val != nil ? int(release_val) : 0
    var activate_req = activate_val != nil ? int(activate_val) : 0
    if release_req == 1 && self.pause_active
      print("[PAUSE] Release requested from LCD")
      self.release_pause()
    end
    if activate_req == 1 && !self.pause_active
      print("[PAUSE] Activate requested from LCD")
      self.activate_pause()
    end
  end

  def sync_lcd_periodic()
    self.sync_lcd_now(false)
  end

  def sync_lcd_critical()
    var now = tasmota.millis()
    if now - self.last_sync_ms < 500
      tasmota.set_timer(600, /-> self.sync_lcd_critical())
      return
    end
    self.sync_lcd_now(true)
  end

  def sync_lcd_now(critical)
    var now = tasmota.millis()
    var cmd_name = critical ? "MBGateCritical" : "MBGate"
    tasmota.cmd(string.format('%s {"deviceaddress":%d,"functioncode":16,"startaddress":%d,"type":"uint16","count":1,"values":[%d],"tag":"err:lcd","quiet":60,"retries":2}', cmd_name, self.LCD_ADDR, self.ERROR_REG, self.error_mask))
    self.last_sent_mask = self.error_mask
    self.last_sync_ms = now
  end

  def sync_lcd(force)
    if !force && self.error_mask == self.last_sent_mask return end
    # Notify cloud logger about error change
    var old_mask = self.last_sent_mask >= 0 ? self.last_sent_mask : 0
    if self.error_mask != old_mask
      try
        global.cloud_logger.on_error_change(self.error_mask, old_mask)
      except ..
      end
    end
    self.sync_lcd_critical()
  end

  def on_reset(bit)
    if bit < 0 || bit > 15 return end
    var now = tasmota.millis()
    if now - self.last_reset_ms < 10000 return end
    var mask = 1 << bit
    if (self.error_mask & mask) == 0 return end
    if now - self.error_set_ms < 5000 return end
    print(string.format("[ERR] Error reset bit %d", bit))
    self.error_mask = self.error_mask & (0xFFFF ^ mask)
    self.last_reset_ms = now
    if bit == 0 && self.mao4_current != nil
      self.mao4_initial = self.mao4_current
      self.restore_mao4_channels()
    elif bit == 1 && self.di_current[5] != nil
      self.di_initial[5] = self.di_current[5]
    elif bit == 2 && self.di_current[3] != nil
      self.di_initial[3] = self.di_current[3]
    elif bit == 3 && self.di_current[4] != nil
      self.di_initial[4] = self.di_current[4]
    elif bit == 15
      self.release_pause()
    end
    tasmota.cmd(string.format('MBGateCritical {"deviceaddress":%d,"functioncode":16,"startaddress":%d,"type":"uint16","count":1,"values":[0],"tag":"err:ack","quiet":30,"retries":3}', self.LCD_ADDR, self.RESET_REG))
    tasmota.set_timer(200, /-> self.sync_lcd(true))
  end

  def is_fan_start_allowed()
    var block_mask = self.ERR_PRESSURE | self.ERR_FILTER_SUPPLY | self.ERR_FILTER_EXHAUST | self.ERR_RECUPERATOR | self.ERR_PAUSE
    return (self.error_mask & block_mask) == 0
  end

  def get_error_mask()
    return self.error_mask
  end

  def has_error(bit)
    return (self.error_mask & (1 << bit)) != 0
  end

  def is_paused()
    return self.pause_active
  end

  def get_counter_info()
    return {
      "mao4_initial": self.mao4_initial, 
      "mao4_current": self.mao4_current, 
      "mao4_init": self.mao4_init,
      "di_initial": self.di_initial,
      "di_current": self.di_current,
      "pause_active": self.pause_active
    }
  end

  def reset_error(bit)
    if bit < 0 || bit > 15 return end
    var mask = 1 << bit
    if (self.error_mask & mask) != 0
      self.error_mask = self.error_mask & (0xFFFF ^ mask)
      if bit == 0 && self.mao4_current != nil
        self.mao4_initial = self.mao4_current
        self.restore_mao4_channels()
      elif bit == 1 && self.di_current[5] != nil
        self.di_initial[5] = self.di_current[5]
      elif bit == 2 && self.di_current[3] != nil
        self.di_initial[3] = self.di_current[3]
      elif bit == 3 && self.di_current[4] != nil
        self.di_initial[4] = self.di_current[4]
      elif bit == 15
        self.pause_active = false
      end
      self.sync_lcd(false)
    end
  end

  def set_error(bit)
    if bit < 0 || bit > 15 return end
    self.error_mask = self.error_mask | (1 << bit)
    if bit == 15 self.pause_active = true end
    self.sync_lcd(false)
  end

  def web_sensor()
    if self.pause_active
      tasmota.web_send_decimal("{s}<b>Статус системы</b>{m}<span style='color:#FF8800'><b>ПАУЗА</b></span>{e}")
    elif self.error_mask != 0
      tasmota.web_send_decimal(string.format("{s}<b>Статус системы</b>{m}<span style='color:#FF4444'><b>ОШИБКИ (0x%04X)</b></span>{e}", self.error_mask))
    else
      tasmota.web_send_decimal("{s}<b>Статус системы</b>{m}<span style='color:#00CC00'><b>OK</b></span>{e}")
    end
    if (self.error_mask & self.ERR_PRESSURE) != 0
      tasmota.web_send_decimal("{s}  • Давление (MAO4){m}<span style='color:#FF4444'>ОШИБКА</span>{e}")
    end
    if (self.error_mask & self.ERR_RECUPERATOR) != 0
      tasmota.web_send_decimal("{s}  • Рекуператор{m}<span style='color:#FF4444'>ОШИБКА</span>{e}")
    end
    if (self.error_mask & self.ERR_FILTER_SUPPLY) != 0
      tasmota.web_send_decimal("{s}  • Приточный фильтр{m}<span style='color:#FF4444'>ОШИБКА</span>{e}")
    end
    if (self.error_mask & self.ERR_FILTER_EXHAUST) != 0
      tasmota.web_send_decimal("{s}  • Вытяжной фильтр{m}<span style='color:#FF4444'>ОШИБКА</span>{e}")
    end
    tasmota.web_send_decimal("{s}<b>Счётчики срабатываний</b>{m}{e}")
    if self.mao4_init
      var mao4_diff = self.mao4_current != nil && self.mao4_initial != nil ? self.mao4_current - self.mao4_initial : 0
      var mao4_color = mao4_diff > 0 ? "#FF4444" : "#888888"
      tasmota.web_send_decimal(string.format("{s}  Давление приток/вытяжка{m}<span style='color:%s'>%d</span> (база: %d){e}", mao4_color, self.mao4_current != nil ? self.mao4_current : 0, self.mao4_initial != nil ? self.mao4_initial : 0))
    end
    if self.di_init[0]
      tasmota.web_send_decimal(string.format("{s}  Внешняя кнопка{m}%d (база: %d){e}", self.di_current[0] != nil ? self.di_current[0] : 0, self.di_initial[0] != nil ? self.di_initial[0] : 0))
    end
    if self.di_init[3]
      var fs_diff = self.di_current[3] != nil && self.di_initial[3] != nil ? self.di_current[3] - self.di_initial[3] : 0
      var fs_color = fs_diff > 0 ? "#FF4444" : "#888888"
      tasmota.web_send_decimal(string.format("{s}  Приточный фильтр{m}<span style='color:%s'>%d</span> (база: %d){e}", fs_color, self.di_current[3] != nil ? self.di_current[3] : 0, self.di_initial[3] != nil ? self.di_initial[3] : 0))
    end
    if self.di_init[4]
      var fe_diff = self.di_current[4] != nil && self.di_initial[4] != nil ? self.di_current[4] - self.di_initial[4] : 0
      var fe_color = fe_diff > 0 ? "#FF4444" : "#888888"
      tasmota.web_send_decimal(string.format("{s}  Вытяжной фильтр{m}<span style='color:%s'>%d</span> (база: %d){e}", fe_color, self.di_current[4] != nil ? self.di_current[4] : 0, self.di_initial[4] != nil ? self.di_initial[4] : 0))
    end
    if self.di_init[5]
      var rec_diff = self.di_current[5] != nil && self.di_initial[5] != nil ? self.di_current[5] - self.di_initial[5] : 0
      var rec_color = rec_diff > 0 ? "#FF4444" : "#888888"
      tasmota.web_send_decimal(string.format("{s}  Рекуператор{m}<span style='color:%s'>%d</span> (база: %d){e}", rec_color, self.di_current[5] != nil ? self.di_current[5] : 0, self.di_initial[5] != nil ? self.di_initial[5] : 0))
    end
  end

  def json_append()
    var pause_str = self.pause_active ? "true" : "false"
    var p0 = (self.error_mask & self.ERR_PRESSURE) != 0 ? "true" : "false"
    var p1 = (self.error_mask & self.ERR_FILTER_SUPPLY) != 0 ? "true" : "false"
    var p2 = (self.error_mask & self.ERR_FILTER_EXHAUST) != 0 ? "true" : "false"
    var p3 = (self.error_mask & self.ERR_RECUPERATOR) != 0 ? "true" : "false"
    tasmota.response_append(string.format(',\"Errors\":{\"Mask\":%d,\"Pause\":%s,\"Pressure\":%s,\"FilterSupply\":%s,\"FilterExhaust\":%s,\"Recuperator\":%s}', self.error_mask, pause_str, p0, p1, p2, p3))
  end
end

var error_handler = ErrorHandler()
global.error_handler = error_handler

tasmota.add_rule("ModBusReceived", def(value, trigger)
  if value == nil return end
  var dev = value['DeviceAddress']
  var fc = value['FunctionCode']
  var sa = value['StartAddress']
  var vals = nil
  try vals = value['Values'] except .. return end
  if dev == 109 && fc == 4 && sa == 32
    if vals != nil && size(vals) > 0
      error_handler.on_mao4_counter(vals[0])
    end
  end
  if dev == 140 && fc == 4 && sa == 32
    if vals != nil && size(vals) >= 6
      error_handler.on_di_batch(vals)
    end
  end
end)

tasmota.add_cmd('ErrorStatus', def(cmd, idx, payload)
  var info = error_handler.get_counter_info()
  var pause_str = info["pause_active"] ? "PAUSED" : "running"
  tasmota.resp_cmnd(string.format("Mask: 0x%04X, State: %s, MAO4: %s (base: %s)", 
    error_handler.get_error_mask(), pause_str,
    str(info["mao4_current"]), str(info["mao4_initial"])))
end)

tasmota.add_cmd('ErrorReset', def(cmd, idx, payload)
  if payload == nil || payload == ""
    tasmota.resp_cmnd("Usage: ErrorReset <bit>")
    return
  end
  error_handler.reset_error(int(payload))
  tasmota.resp_cmnd_done()
end)

tasmota.add_cmd('ErrorSet', def(cmd, idx, payload)
  if payload == nil || payload == ""
    tasmota.resp_cmnd("Usage: ErrorSet <bit>")
    return
  end
  error_handler.set_error(int(payload))
  tasmota.resp_cmnd_done()
end)

tasmota.add_cmd('PauseStatus', def(cmd, idx, payload)
  var status = error_handler.is_paused() ? "PAUSED" : "RUNNING"
  tasmota.resp_cmnd(string.format('{"Pause":"%s"}', status))
end)

tasmota.add_cmd('PauseRelease', def(cmd, idx, payload)
  error_handler.release_pause()
  tasmota.resp_cmnd_done()
end)

tasmota.add_cmd('PauseActivate', def(cmd, idx, payload)
  error_handler.activate_pause()
  tasmota.resp_cmnd_done()
end)
