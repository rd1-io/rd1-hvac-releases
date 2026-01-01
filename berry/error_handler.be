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
    try global.mb(self.MAO4_ADDR, 4, self.MAO4_COUNTER_REG, 1, nil, "err:mao4", true) except .. end
  end

  def poll_di_batch()
    var now = tasmota.millis()
    if now - self.last_di_poll_ms < 1000 return end
    self.last_di_poll_ms = now
    try global.mb(self.DI_ADDR, 4, self.DI_START_REG, self.DI_REG_COUNT, nil, "err:di", true) except .. end
  end

  def emergency_fan_stop()
    try global.mb(self.MAO4_ADDR, 16, self.SUPPLY_REG, 1, "0", "err:emrg", true) except .. end
    tasmota.set_timer(100, def()
      try global.mb(self.MAO4_ADDR, 16, self.EXHAUST_REG, 1, "0", "err:emrg", true) except .. end
    end)
  end

  def restore_mao4_channels()
    try global.mb(self.MAO4_ADDR, 16, self.SUPPLY_REG, 1, "0", "err:rst", false) except .. end
    tasmota.set_timer(200, def() try global.mb(self.MAO4_ADDR, 16, self.EXHAUST_REG, 1, "0", "err:rst", false) except .. end end)
    tasmota.set_timer(400, def() try tasmota.cmd(string.format('MBGate {"deviceaddress":%d,"functioncode":5,"startaddress":%d,"type":"bit","count":1,"values":[1],"tag":"err:rst","quiet":30,"retries":2}', self.MAO4_ADDR, self.SUPPLY_REG)) except .. end end)
    tasmota.set_timer(600, def() try tasmota.cmd(string.format('MBGate {"deviceaddress":%d,"functioncode":5,"startaddress":%d,"type":"bit","count":1,"values":[1],"tag":"err:rst","quiet":30,"retries":2}', self.MAO4_ADDR, self.EXHAUST_REG)) except .. end end)
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
        self.emergency_fan_stop()
        self.sync_lcd(false)
      end
    end
    if self.di_init[4] && self.di_current[4] != self.di_initial[4]
      if (self.error_mask & self.ERR_FILTER_EXHAUST) == 0
        self.error_mask = self.error_mask | self.ERR_FILTER_EXHAUST
        self.error_set_ms = tasmota.millis()
        self.emergency_fan_stop()
        self.sync_lcd(false)
      end
    end
    if self.di_init[5] && self.di_current[5] != self.di_initial[5]
      if (self.error_mask & self.ERR_RECUPERATOR) == 0
        self.error_mask = self.error_mask | self.ERR_RECUPERATOR
        self.error_set_ms = tasmota.millis()
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
    try global.mb(self.LCD_ADDR, 16, self.PAUSE_RELEASE_REG, 1, "0", "err:pclr", false) except .. end
    self.sync_lcd(false)
  end

  def on_pause_control(release_val, activate_val)
    var release_req = release_val != nil ? int(release_val) : 0
    var activate_req = activate_val != nil ? int(activate_val) : 0
    if release_req == 1 && self.pause_active
      self.release_pause()
    end
    if activate_req == 1 && !self.pause_active
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
    try
      global.mb(self.LCD_ADDR, 16, self.ERROR_REG, 1, str(self.error_mask), "err:lcd", critical)
      self.last_sent_mask = self.error_mask
      self.last_sync_ms = now
    except .. end
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
    try global.mb(self.LCD_ADDR, 16, self.RESET_REG, 1, "0", "err:ack", true) except .. end
    tasmota.set_timer(200, /-> self.sync_lcd(true))
  end

  def is_fan_start_allowed()
    var block_mask = self.ERR_PRESSURE | self.ERR_FILTER_SUPPLY | self.ERR_FILTER_EXHAUST | self.ERR_RECUPERATOR | self.ERR_PAUSE
    return (self.error_mask & block_mask) == 0
  end

  def get_error_mask()
    return self.error_mask
  end

  def web_sensor()
    if self.pause_active
      tasmota.web_send_decimal("{s}<b>Статус</b>{m}<span style='color:#FF8800'><b>ПАУЗА</b></span>{e}")
    elif self.error_mask != 0
      tasmota.web_send_decimal("{s}<b>Статус</b>{m}<span style='color:#FF4444'><b>ОШИБКА</b></span>{e}")
    else
      tasmota.web_send_decimal("{s}<b>Статус</b>{m}<span style='color:#00CC00'><b>OK</b></span>{e}")
    end
    if (self.error_mask & self.ERR_PRESSURE) != 0
      tasmota.web_send_decimal("{s}• Давление{m}<span style='color:#FF4444'>ERR</span>{e}")
    end
    if (self.error_mask & self.ERR_RECUPERATOR) != 0
      tasmota.web_send_decimal("{s}• Рекуператор{m}<span style='color:#FF4444'>ERR</span>{e}")
    end
    if (self.error_mask & self.ERR_FILTER_SUPPLY) != 0
      tasmota.web_send_decimal("{s}• Фильтр приток{m}<span style='color:#FF4444'>ERR</span>{e}")
    end
    if (self.error_mask & self.ERR_FILTER_EXHAUST) != 0
      tasmota.web_send_decimal("{s}• Фильтр вытяжка{m}<span style='color:#FF4444'>ERR</span>{e}")
    end
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
