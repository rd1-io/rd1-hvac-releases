import string

class LCDBridge
  static var LCD_ADDR = 23
  static var STATUS_REG = 100
  static var STATUS_COUNT = 13
  static var ENV_REG = 200
  static var ENV_COUNT = 20
  static var MATTER_STATUS_REG = 300
  static var MATTER_PAIRING_REG = 301
  static var OTA_STATUS_REG = 400
  static var VERSION_REG = 218
  var co2_ppm, indoor_t, indoor_h, ds18_1, ds18_2, ds18_3
  var lcd_target_c, lcd_power, last_pid_c, last_power_lvl
  var last_batch_ms, fail_count, safety_triggered, matter_processing
  var preset, preset_sent, preset_ms, preset_apply_ms
  var echo_suppress_ms, change_source, change_ms

  def init()
    self.co2_ppm = nil
    self.indoor_t = nil
    self.indoor_h = nil
    self.ds18_1 = nil
    self.ds18_2 = nil
    self.ds18_3 = nil
    self.lcd_target_c = nil
    self.lcd_power = nil
    self.last_pid_c = nil
    self.last_power_lvl = nil
    self.last_batch_ms = 0
    self.fail_count = 0
    self.safety_triggered = false
    self.matter_processing = false
    self.preset = nil
    self.preset_sent = nil
    self.preset_ms = 0
    self.preset_apply_ms = 0
    self.echo_suppress_ms = 0
    self.change_source = ""
    self.change_ms = 0
    tasmota.add_driver(self)
    tasmota.set_timer(4000, /-> self.init_poll())
    tasmota.set_timer(6000, /-> self.status_timer())
    tasmota.set_timer(12000, /-> self.batch_timer())
    tasmota.set_timer(35000, /-> self.ds18_timer())
  end

  def init_poll()
    try tasmota.cmd("BinRead") except .. end
    tasmota.set_timer(5000, /-> self.publish_batch())
    tasmota.set_timer(8000, /-> self.send_version())
  end

  # Send Berry version to LCD (simple integer)
  def send_version()
    import persist
    var ver = persist.find("berry_version")
    if ver == nil ver = 0 end
    ver = int(ver)
    self.write_u16(self.VERSION_REG, ver)
  end

  def status_timer()
    self.fail_count += 1
    if self.fail_count >= 3 && !self.safety_triggered
      self.safety_shutdown()
    end
    self.request_status()
    tasmota.set_timer(6099, /-> self.status_timer(), "lcd_status")
  end

  def batch_timer()
    self.publish_batch()
    tasmota.set_timer(9034, /-> self.batch_timer(), "lcd_batch")
  end

  def ds18_timer()
    var r = tasmota.cmd("Status 10")
    if r != nil
      var sns = r.find("StatusSNS")
      if sns != nil
        var t1 = nil, t2 = nil, t3 = nil
        try t1 = sns["DS18B20-1"]["Temperature"] except .. end
        try t2 = sns["DS18B20-2"]["Temperature"] except .. end
        try t3 = sns["DS18B20-3"]["Temperature"] except .. end
        self.on_ds18(t1, t2, t3)
      end
    end
    tasmota.set_timer(29989, /-> self.ds18_timer(), "lcd_ds18")
  end

  def safety_shutdown()
    self.safety_triggered = true
    try global.fan_ctrl.set_power_level(0) except .. tasmota.cmd("VentPowerLevel 0") end
  end

  def on_response_ok()
    self.fail_count = 0
    self.safety_triggered = false
  end

  def write_u16(reg, val)
    if val == nil return end
    val = val < 0 ? 0 : (val > 65535 ? 65535 : int(val))
    try global.mb(self.LCD_ADDR, 16, reg, 1, str(val), "lcd:w16", false) except .. end
  end

  def write_multi(reg, vals)
    if vals == nil || size(vals) == 0 return end
    var buf = ""
    for i: 0 .. size(vals) - 1
      var v = vals[i] != nil ? int(vals[i]) : 0
      v = v < 0 ? 0 : (v > 65535 ? 65535 : v)
      buf += (i > 0 ? "," : "") + str(v)
    end
    try global.mb(self.LCD_ADDR, 16, reg, size(vals), buf, "lcd:env", false) except .. end
  end

  def request_status()
    try global.mb(self.LCD_ADDR, 3, self.STATUS_REG, self.STATUS_COUNT, nil, "lcd:sta", true) except .. end
  end

  def on_co2(ppm)
    if ppm != nil self.co2_ppm = ppm end
  end

  def on_indoor_t(t)
    if t != nil self.indoor_t = t end
  end

  def on_indoor_h(h)
    if h != nil self.indoor_h = h end
  end

  def on_ds18(t1, t2, t3)
    if t1 != nil self.ds18_1 = t1 end
    if t2 != nil self.ds18_2 = t2 end
    if t3 != nil self.ds18_3 = t3 end
  end

  def apply_pid(temp_c)
    if temp_c == nil return end
    var now = tasmota.millis()
    var t10 = int(temp_c * 10)
    if self.last_pid_c != nil
      var diff = t10 - int(self.last_pid_c * 10)
      if diff < 0 diff = -diff end
      if diff < 1 && now - self.preset_apply_ms < 5000 return end
    end
    tasmota.cmd(string.format("PidSp %.1f", temp_c))
    self.last_pid_c = temp_c
  end

  def apply_power(lvl)
    if lvl == nil return end
    lvl = int(lvl)
    lvl = lvl < 0 ? 0 : (lvl > 5 ? 5 : lvl)
    var now = tasmota.millis()
    if self.last_power_lvl != nil && self.last_power_lvl == lvl && now - self.preset_apply_ms < 3000 return end
    try global.fan_ctrl.set_power_level(lvl) except .. tasmota.cmd(string.format("VentPowerLevel %d", lvl)) end
    self.last_power_lvl = lvl
    self.preset_apply_ms = now
  end

  def get_binary_mask()
    # Binary sensors moved to error_handler, this returns 0 for backwards compatibility
    return 0
  end

  def collect_env_values()
    var t_out = nil
    var h_out = nil
    try t_out = global.sht20_outdoor.temp_c except .. end
    try h_out = global.sht20_outdoor.humi_pct except .. end
    var vpos = nil
    try vpos = global.valve_bridge.last_pct except .. end
    var supply_pct = 0
    var exhaust_pct = 0
    try
      supply_pct = int(global.fan_ctrl.supply_pct)
      exhaust_pct = int(global.fan_ctrl.exhaust_pct)
    except ..
    end
    var filter_wear = 0
    try filter_wear = int(global.filter_wear.promille) except .. end
    var uptime = tasmota.cmd("Status 11")
    var uptime_sec = 0
    try uptime_sec = uptime["StatusSTS"]["UptimeSec"] except .. end
    var ip = self.get_ip_string()
    var ip1 = 0
    var ip2 = 0
    if ip != nil
      var octets = string.split(ip, '.')
      if size(octets) == 4
        ip1 = (int(octets[0]) << 8) | int(octets[1])
        ip2 = (int(octets[2]) << 8) | int(octets[3])
      end
    end
    var err_mask = 0
    try err_mask = global.error_handler.error_mask except .. end
    # Get Berry version
    import persist
    var cu_ver = persist.find("berry_version")
    if cu_ver == nil cu_ver = 0 end
    cu_ver = int(cu_ver)
    # Get exhaust mode status
    var exhaust_mode_active = 0
    try exhaust_mode_active = global.exhaust_mode != nil && global.exhaust_mode.is_active() ? 1 : 0 except .. end
    return [
      err_mask,                                            # reg 200
      self.indoor_t != nil ? int(self.indoor_t * 10) : 0,  # reg 201
      self.indoor_h != nil ? int(self.indoor_h * 10) : 0,  # reg 202
      self.co2_ppm != nil ? int(self.co2_ppm) : 0,         # reg 203
      self.ds18_1 != nil ? int(self.ds18_1 * 10) : 0,      # reg 204
      self.ds18_2 != nil ? int(self.ds18_2 * 10) : 0,      # reg 205
      self.ds18_3 != nil ? int(self.ds18_3 * 10) : 0,      # reg 206
      t_out != nil ? int(t_out * 10) : 0,                  # reg 207
      h_out != nil ? int(h_out * 10) : 0,                  # reg 208
      vpos != nil ? int(vpos) : 0,                         # reg 209
      self.get_binary_mask(),                              # reg 210
      supply_pct,                                          # reg 211
      exhaust_pct,                                         # reg 212
      filter_wear,                                         # reg 213
      uptime_sec & 0xFFFF,                                 # reg 214
      (uptime_sec >> 16) & 0xFFFF,                         # reg 215
      ip1,                                                 # reg 216
      ip2,                                                 # reg 217
      cu_ver,                                              # reg 218
      exhaust_mode_active                                  # reg 219
    ]
  end

  def get_ip_string()
    var ip = nil
    try
      var eth = tasmota.eth()
      if eth != nil && eth.find('up') == true ip = eth.find('ip') end
    except .. end
    if ip == nil || ip == "" || ip == "0.0.0.0"
      try
        var wifi = tasmota.wifi()
        if wifi != nil && wifi.find('up') == true ip = wifi.find('ip') end
      except .. end
    end
    if ip == nil || ip == "" || ip == "0.0.0.0" return nil end
    return ip
  end

  def publish_batch()
    var now = tasmota.millis()
    if now - self.last_batch_ms < 800
      tasmota.set_timer(800 - (now - self.last_batch_ms), /-> self.publish_batch())
      return
    end
    self.write_multi(self.ENV_REG, self.collect_env_values())
    self.last_batch_ms = tasmota.millis()
  end

  def apply_preset_lcd(p)
    if p == nil return end
    p = p < 1 ? 1 : (p > 4 ? 4 : int(p))
    var now = tasmota.millis()
    if self.change_source == "tasmota" && now - self.change_ms < 7000 return end
    if now - self.preset_apply_ms < 400 return end
    if self.preset != nil && self.preset == p && now - self.preset_apply_ms < 3000 return end
    self.echo_suppress_ms = now + 2000
    if p == 1 tasmota.cmd("Backlog Power7 ON; Power8 OFF; Power9 OFF; Power10 OFF")
    elif p == 2 tasmota.cmd("Backlog Power7 OFF; Power8 ON; Power9 OFF; Power10 OFF")
    elif p == 3 tasmota.cmd("Backlog Power7 OFF; Power8 OFF; Power9 ON; Power10 OFF")
    else tasmota.cmd("Backlog Power7 OFF; Power8 OFF; Power9 OFF; Power10 ON") end
    self.preset = p
    self.preset_apply_ms = now
    self.change_source = "lcd"
    self.change_ms = now
  end

  def write_preset(p)
    if p == nil return end
    p = p < 1 ? 1 : (p > 4 ? 4 : int(p))
    var now = tasmota.millis()
    if self.preset_sent != nil && self.preset_sent == p && now - self.preset_ms < 3000 return end
    if now - self.preset_ms < 600 return end
    self.write_u16(102, p)
    self.preset_sent = p
    self.preset_ms = now
  end

  def apply_balance_lcd(bal)
    if bal == nil return end
    bal = int(bal)
    if bal < 50 bal = 50 end
    if bal > 150 bal = 150 end
    tasmota.cmd(string.format("ExhaustMultiplier %d", bal))
  end

  def apply_exhaust_mode_balance_lcd(bal)
    if bal == nil return end
    bal = int(bal)
    if bal < 50 bal = 50 end
    if bal > 150 bal = 150 end
    tasmota.cmd(string.format("ExhaustModeMultiplier %d", bal))
  end

  def on_filter_reset(val)
    if val == nil || val != 1 return end
    try global.filter_wear.reset() except .. end
  end

  def on_ota_request(val)
    if val == nil || val != 1 return end
    self.write_u16(self.OTA_STATUS_REG, 1)
    tasmota.set_timer(1000, /-> self.start_ota())
  end

  def start_ota()
    self.write_u16(self.OTA_STATUS_REG, 1)
    # Load and run OTA updater
    var bridge = self
    tasmota.set_timer(500, def()
      try
        load("ota_update.be")
        global.ota_start_update()
      except ..
        bridge.write_u16(bridge.OTA_STATUS_REG, 3)
      end
    end)
  end

  def on_power_state(pwr, val)
    var now = tasmota.millis()
    if now < self.echo_suppress_ms
      var exp = nil
      if self.preset == 1 exp = 7 elif self.preset == 2 exp = 8 elif self.preset == 3 exp = 9 elif self.preset == 4 exp = 10 end
      if exp != nil && pwr == exp return end
    end
    if val != "ON" && val != 1 && val != "1" return end
    var p = nil
    if pwr == 7 p = 1 elif pwr == 8 p = 2 elif pwr == 9 p = 3 elif pwr == 10 p = 4 else return end
    self.echo_suppress_ms = now + 2000
    if p == 1 tasmota.cmd("Backlog Power7 ON; Power8 OFF; Power9 OFF; Power10 OFF")
    elif p == 2 tasmota.cmd("Backlog Power7 OFF; Power8 ON; Power9 OFF; Power10 OFF")
    elif p == 3 tasmota.cmd("Backlog Power7 OFF; Power8 OFF; Power9 ON; Power10 OFF")
    else tasmota.cmd("Backlog Power7 OFF; Power8 OFF; Power9 OFF; Power10 ON") end
    self.change_source = "tasmota"
    self.change_ms = now
    self.preset = p
    self.preset_apply_ms = now
    self.write_preset(p)
  end

  def handle_matter()
    if self.matter_processing return end
    self.matter_processing = true
    self.write_u16(103, 0)
    tasmota.cmd("MtrJoin 1")
    var matter_dev = nil
    for d: tasmota._drivers
      if string.find(str(d), 'Matter_Device') >= 0
        matter_dev = d
        break
      end
    end
    if matter_dev != nil && matter_dev.commissioning != nil
      var manual = str(matter_dev.commissioning.compute_manual_pairing_code())
      var p1 = 0, p2 = 0, p3 = 0
      if size(manual) >= 11
        p1 = int(manual[0..3])
        p2 = int(manual[4..6])
        p3 = int(manual[7..10])
      end
      # Send status (1=commissioning open) and pairing code as single batch
      # Registers: 300=status, 301=p1, 302=p2, 303=p3
      self.write_multi(self.MATTER_STATUS_REG, [1, p1, p2, p3])
    end
    tasmota.set_timer(5000, def() self.matter_processing = false end)
  end

  def on_matter_reset()
    try
      import path
      if path.exists("/_matter_fabrics.json")
        path.remove("/_matter_fabrics.json")
      end
    except ..
    end
    tasmota.set_timer(1000, /-> tasmota.cmd("Restart 1"))
  end

end

var lcd_bridge = LCDBridge()
global.lcd_presets = lcd_bridge

tasmota.add_rule("ModBusReceived", def(value, trigger)
  if value == nil return end
  var dev = value['DeviceAddress']
  var fc = value['FunctionCode']
  var sa = value['StartAddress']
  var vals = nil
  try vals = value['Values'] except .. end
  if dev == 1 && fc == 3 && sa == 2 && vals != nil && size(vals) > 0
    lcd_bridge.on_co2(int(vals[0]))
  end
  if dev == 23 && fc == 3 && sa == 100 && vals != nil && size(vals) >= 12
    lcd_bridge.on_response_ok()
    if vals[0] != nil
      lcd_bridge.lcd_target_c = int(vals[0]) / 10.0
      lcd_bridge.apply_pid(lcd_bridge.lcd_target_c)
    end
    if vals[1] != nil
      var lvl = int(vals[1])
      lvl = lvl < 0 ? 0 : (lvl > 5 ? 5 : lvl)
      lcd_bridge.lcd_power = lvl
      lcd_bridge.apply_power(lvl)
    end
    if vals[2] != nil
      var p = int(vals[2])
      p = p < 1 ? 1 : (p > 4 ? 4 : p)
      lcd_bridge.apply_preset_lcd(p)
    end
    if vals[3] != nil && int(vals[3]) == 1 && !lcd_bridge.matter_processing
      lcd_bridge.handle_matter()
    end
    if vals[4] != nil
      var v = int(vals[4])
      if v >= 1 && v <= 16
        try global.error_handler.on_reset(v - 1) except .. end
      end
    end
    if vals[5] != nil && int(vals[5]) == 1
      tasmota.cmd("Restart 1")
    end
    if vals[6] != nil
      lcd_bridge.apply_balance_lcd(int(vals[6]))
    end
    if vals[7] != nil
      lcd_bridge.on_filter_reset(int(vals[7]))
    end
    if vals[8] != nil || vals[9] != nil
      try global.error_handler.on_pause_control(vals[8], vals[9]) except .. end
    end
    if vals[10] != nil
      lcd_bridge.on_ota_request(int(vals[10]))
    end
    if vals[11] != nil
      lcd_bridge.apply_exhaust_mode_balance_lcd(int(vals[11]))
    end
    if vals[12] != nil && int(vals[12]) == 1
      lcd_bridge.on_matter_reset()
    end
  end
  if dev == 10 && fc == 4 && sa == 1 && vals != nil && size(vals) >= 2
    lcd_bridge.on_indoor_t(int(vals[0]) / 10.0)
    lcd_bridge.on_indoor_h(int(vals[1]) / 10.0)
  end
end)

def parse_ds18(js)
  var t1 = nil, t2 = nil, t3 = nil
  try t1 = js["DS18B20-1"]["Temperature"] except .. end
  try t2 = js["DS18B20-2"]["Temperature"] except .. end
  try t3 = js["DS18B20-3"]["Temperature"] except .. end
  if t1 != nil || t2 != nil || t3 != nil lcd_bridge.on_ds18(t1, t2, t3) end
end

tasmota.add_rule("RESULT", def(v, t) if v != nil parse_ds18(v.find("StatusSNS", v)) end end)
tasmota.add_rule("Tele-JSON", def(v, t) if v != nil parse_ds18(v) end end)
tasmota.add_rule("Power7#State", def(v, t) lcd_bridge.on_power_state(7, v) end)
tasmota.add_rule("Power8#State", def(v, t) lcd_bridge.on_power_state(8, v) end)
tasmota.add_rule("Power9#State", def(v, t) lcd_bridge.on_power_state(9, v) end)
tasmota.add_rule("Power10#State", def(v, t) lcd_bridge.on_power_state(10, v) end)
tasmota.add_rule("Matter#Commissioning", def(v, t) if v != nil lcd_bridge.write_u16(300, int(v)) end end)
