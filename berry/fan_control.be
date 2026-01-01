import string
import json
import persist

class FanController
  static var MAO4_ADDR = 109
  static var SUPPLY_REG = 16
  static var EXHAUST_REG = 17
  static var VALVE_DELAY_MS = 25000
  static var SHUTDOWN_RETRY_MAX = 5
  static var SHUTDOWN_RETRY_INTERVAL_MS = 300
  static var SHUTDOWN_VALVE_DELAY_MS = 1500
  static var MIN_MOTOR_PCT = 10
  var supply_pct, exhaust_pct, exhaust_mult, exhaust_mode_mult, power_level
  var valve_is_opening, valve_open, valve_open_cmd_ms
  var shutdown_in_progress, shutdown_retry_count
  var mao4_supply, mao4_exhaust, mao4_read_ms

  def init()
    self.supply_pct = 0
    self.exhaust_pct = 0
    # Load exhaust_mult from persist (0.5-1.5, default 1.0)
    self.exhaust_mult = persist.find('exhaust_mult', 1.0)
    if self.exhaust_mult < 0.5 self.exhaust_mult = 0.5 end
    if self.exhaust_mult > 1.5 self.exhaust_mult = 1.5 end
    # Load exhaust_mode_mult from persist (0.5-1.5, default 0.75 = 75%)
    self.exhaust_mode_mult = persist.find('exhaust_mode_mult', 0.75)
    if self.exhaust_mode_mult < 0.5 self.exhaust_mode_mult = 0.5 end
    if self.exhaust_mode_mult > 1.5 self.exhaust_mode_mult = 1.5 end
    self.power_level = 0
    self.valve_is_opening = false
    self.valve_open = false
    self.valve_open_cmd_ms = 0
    self.shutdown_in_progress = false
    self.shutdown_retry_count = 0
    self.mao4_supply = nil
    self.mao4_exhaust = nil
    self.mao4_read_ms = 0
    tasmota.add_driver(self)
  end

  def clamp(p)
    return p < 0 ? 0 : (p > 100 ? 100 : p)
  end

  # Clamp motor percentage: if > 0, ensure at least MIN_MOTOR_PCT
  def clamp_motor(p)
    if p <= 0 return 0 end
    if p < self.MIN_MOTOR_PCT return self.MIN_MOTOR_PCT end
    if p > 100 return 100 end
    return p
  end

  def write_pct(reg, pct)
    var val = int(pct)
    if val < 0 val = 0 end
    if val > 100 val = 100 end
    tasmota.cmd(string.format('MBGate {"deviceaddress":%d,"functioncode":16,"startaddress":%d,"type":"uint16","count":1,"values":[%d],"tag":"mao4:w16:","quiet":30,"retries":2}', self.MAO4_ADDR, reg, val))
  end

  def emergency_stop()
    tasmota.cmd(string.format('MBGateCritical {"deviceaddress":%d,"functioncode":16,"startaddress":%d,"type":"uint16","count":1,"values":[0],"tag":"fan:emrg","quiet":30,"retries":3}', self.MAO4_ADDR, self.SUPPLY_REG))
    tasmota.set_timer(100, /-> tasmota.cmd(string.format('MBGateCritical {"deviceaddress":%d,"functioncode":16,"startaddress":%d,"type":"uint16","count":1,"values":[0],"tag":"fan:emrg","quiet":30,"retries":3}', self.MAO4_ADDR, self.EXHAUST_REG)))
    self.supply_pct = 0
    self.exhaust_pct = 0
  end

  def start_safety_shutdown()
    if self.shutdown_in_progress return end
    self.shutdown_in_progress = true
    self.shutdown_retry_count = 0
    self.valve_open = false
    self.power_level = 0
    self.valve_is_opening = false
    self.valve_open_cmd_ms = 0
    tasmota.remove_timer("fan_shutdown_retry")
    tasmota.remove_timer("fan_shutdown_complete")
    tasmota.remove_timer("fan_verify")
    self.do_shutdown_retry()
  end

  def do_shutdown_retry()
    if !self.shutdown_in_progress return end
    self.shutdown_retry_count += 1
    self.emergency_stop()
    if self.shutdown_retry_count < self.SHUTDOWN_RETRY_MAX
      tasmota.set_timer(self.SHUTDOWN_RETRY_INTERVAL_MS, /-> self.do_shutdown_retry(), "fan_shutdown_retry")
    else
      tasmota.set_timer(self.SHUTDOWN_VALVE_DELAY_MS, /-> self.complete_shutdown(), "fan_shutdown_complete")
    end
  end

  def complete_shutdown()
    if !self.shutdown_in_progress return end
    tasmota.cmd("Power1 OFF")
    self.shutdown_in_progress = false
    tasmota.set_timer(2000, /-> self.verify_stopped(), "fan_verify")
  end

  def verify_stopped()
    if self.power_level != 0 || self.shutdown_in_progress return end
    self.read_register(self.SUPPLY_REG)
    tasmota.set_timer(300, /-> self.read_register(self.EXHAUST_REG))
    tasmota.set_timer(1000, /-> self.check_verify())
  end

  def check_verify()
    if self.power_level != 0 || self.shutdown_in_progress return end
    var need_stop = false
    if self.mao4_supply != nil && self.mao4_supply > 0 need_stop = true end
    if self.mao4_exhaust != nil && self.mao4_exhaust > 0 need_stop = true end
    if need_stop
      self.emergency_stop()
      tasmota.set_timer(3000, /-> self.verify_stopped(), "fan_verify")
    end
  end

  def on_mao4_read(reg, val)
    var pct = val
    if reg == self.SUPPLY_REG self.mao4_supply = pct
    elif reg == self.EXHAUST_REG self.mao4_exhaust = pct end
    self.mao4_read_ms = tasmota.millis()
  end

  def set_supply(pct)
    pct = self.clamp(pct)
    self.supply_pct = pct
    self.write_pct(self.SUPPLY_REG, pct)
  end

  def set_exhaust(pct)
    pct = self.clamp(pct)
    self.exhaust_pct = pct
    self.write_pct(self.EXHAUST_REG, pct)
  end

  def read_register(reg)
    tasmota.cmd(string.format('MBGate {"deviceaddress":%d,"functioncode":3,"startaddress":%d,"type":"uint16","count":1,"tag":"mao4:r03:","quiet":30,"retries":2}', self.MAO4_ADDR, reg))
  end

  # Get the active balance multiplier (exhaust mode or normal)
  def get_active_mult()
    var in_exhaust_mode = false
    try in_exhaust_mode = global.exhaust_mode != nil && global.exhaust_mode.is_active() except .. end
    return in_exhaust_mode ? self.exhaust_mode_mult : self.exhaust_mult
  end

  # Calculate and set both motors based on power level and balance
  # mult: 0.5-1.5 (50%-150%)
  # If mult <= 1.0: supply = base, exhaust = base * mult
  # If mult > 1.0: exhaust = base, supply = base / mult
  def set_both(lvl)
    if self.power_level != 0 && lvl != 0 lvl = self.power_level end
    if lvl != self.power_level return end
    var base_pct = lvl * 20
    var s_pct = 0
    var e_pct = 0
    
    if base_pct > 0
      var mult = self.get_active_mult()
      if mult <= 1.0
        # Balance <= 100%: supply at full, exhaust reduced
        s_pct = base_pct
        e_pct = base_pct * mult
      else
        # Balance > 100%: exhaust at full, supply reduced
        e_pct = base_pct
        s_pct = base_pct / mult
      end
      # Apply minimum motor threshold
      s_pct = self.clamp_motor(s_pct)
      e_pct = self.clamp_motor(e_pct)
    end
    
    self.set_supply(s_pct)
    var ep = e_pct
    tasmota.set_timer(200, /-> self.set_exhaust(ep))
  end

  def set_power_level(lvl)
    lvl = int(lvl)
    if lvl < 0 lvl = 0 end
    if lvl > 5 lvl = 5 end
    if lvl > 0
      try
        if !global.error_handler.is_fan_start_allowed() return end
      except .. end
    end
    if lvl == 0
      if self.power_level == 0 && !self.valve_open && !self.valve_is_opening && !self.shutdown_in_progress return end
      if self.shutdown_in_progress return end
      self.start_safety_shutdown()
      return
    end
    if self.power_level > 0 && lvl > 0 && self.valve_open
      self.power_level = lvl
      self.set_both(lvl)
      return
    end
    try
      if !global.error_handler.is_fan_start_allowed() return end
    except .. end
    if self.valve_is_opening
      self.power_level = lvl
      return
    end
    self.power_level = lvl
    self.valve_is_opening = true
    self.valve_open_cmd_ms = tasmota.millis()
    tasmota.cmd("Power1 ON")
    tasmota.set_timer(self.VALVE_DELAY_MS, def()
      self.valve_open = true
      self.valve_is_opening = false
      if self.power_level > 0
        var can_start = true
        try can_start = global.error_handler.is_fan_start_allowed() except .. end
        if can_start self.set_both(self.power_level) end
      end
    end)
  end

  def web_sensor()
    tasmota.web_send_decimal(string.format("{s}Приточный вентилятор{m}%i %%{e}", int(self.supply_pct)))
    tasmota.web_send_decimal(string.format("{s}Вытяжной вентилятор{m}%i %%{e}", int(self.exhaust_pct)))
    tasmota.web_send_decimal(string.format("{s}Баланс приток/вытяжка{m}%i %%{e}", int(self.exhaust_mult * 100)))
    tasmota.web_send_decimal(string.format("{s}Баланс режима вытяжки{m}%i %%{e}", int(self.exhaust_mode_mult * 100)))
  end

  def json_append()
    tasmota.response_append(string.format(',\"Fans\":{\"Supply\":%i,\"Exhaust\":%i,\"Balance\":%i,\"ExhaustModeBalance\":%i,\"Unit\":\"%%\"}', int(self.supply_pct), int(self.exhaust_pct), int(self.exhaust_mult * 100), int(self.exhaust_mode_mult * 100)))
  end

  def every_second()
    if self.shutdown_in_progress return end
    if self.power_level > 0
      try
        if !global.error_handler.is_fan_start_allowed()
          self.start_safety_shutdown()
          return
        end
      except .. end
    end
    if self.power_level == 0 && !self.valve_open && !self.valve_is_opening
      if tasmota.get_power(0) tasmota.cmd("Power1 OFF") end
      var now = tasmota.millis()
      if now - self.mao4_read_ms > 15000
        self.mao4_read_ms = now
        self.read_register(self.SUPPLY_REG)
        tasmota.set_timer(200, /-> self.read_register(self.EXHAUST_REG))
      end
      if self.mao4_supply != nil && self.mao4_supply > 0
        self.emergency_stop()
        self.mao4_supply = nil
      end
      if self.mao4_exhaust != nil && self.mao4_exhaust > 0
        self.emergency_stop()
        self.mao4_exhaust = nil
      end
    end
    if self.power_level > 0
      var can_run = true
      try can_run = global.error_handler.is_fan_start_allowed() except .. end
      if can_run
        if !tasmota.get_power(0) tasmota.cmd("Power1 ON") end
      end
    end
    if self.power_level > 0 && !self.valve_open && !self.valve_is_opening
      var can_start = true
      try can_start = global.error_handler.is_fan_start_allowed() except .. end
      if !can_start return end
      self.valve_is_opening = true
      self.valve_open_cmd_ms = tasmota.millis()
      tasmota.cmd("Power1 ON")
      tasmota.set_timer(self.VALVE_DELAY_MS, def()
        self.valve_open = true
        self.valve_is_opening = false
        if self.power_level > 0
          var can_start = true
          try can_start = global.error_handler.is_fan_start_allowed() except .. end
          if can_start self.set_both(self.power_level) end
        end
      end)
    end
  end
end

var fan_ctrl = FanController()
global.fan_ctrl = fan_ctrl

tasmota.add_cmd('SupplySpeed', def(cmd, idx, payload)
  if payload == nil || payload == "" fan_ctrl.read_register(fan_ctrl.SUPPLY_REG)
  else fan_ctrl.set_supply(int(payload)) end
  tasmota.resp_cmnd_done()
end)

tasmota.add_cmd('VentPowerLevel', def(cmd, idx, payload)
  fan_ctrl.set_power_level(int(payload))
  tasmota.resp_cmnd_done()
end)

tasmota.add_cmd('ExhaustMultiplier', def(cmd, idx, payload)
  # Accept 50-150 (percent) or 0.5-1.5 (multiplier)
  var m = json.load(payload)
  if m == nil m = real(payload) end
  # Convert percent to multiplier if > 2
  if m > 2 m = m / 100.0 end
  # Clamp to valid range 0.5-1.5
  if m < 0.5 m = 0.5 end
  if m > 1.5 m = 1.5 end
  fan_ctrl.exhaust_mult = m
  # Save to persist
  persist.exhaust_mult = m
  persist.save()
  # Re-apply current power level with new balance
  if fan_ctrl.power_level > 0 && fan_ctrl.valve_open
    fan_ctrl.set_both(fan_ctrl.power_level)
  end
  tasmota.resp_cmnd(string.format('{"ExhaustMultiplier":%i}', int(m * 100)))
end)

tasmota.add_cmd('ExhaustModeMultiplier', def(cmd, idx, payload)
  # Accept 50-150 (percent) or 0.5-1.5 (multiplier) for exhaust mode balance
  var m = json.load(payload)
  if m == nil m = real(payload) end
  # Convert percent to multiplier if > 2
  if m > 2 m = m / 100.0 end
  # Clamp to valid range 0.5-1.5
  if m < 0.5 m = 0.5 end
  if m > 1.5 m = 1.5 end
  fan_ctrl.exhaust_mode_mult = m
  # Save to persist
  persist.exhaust_mode_mult = m
  persist.save()
  # Re-apply current power level with new balance if in exhaust mode
  var in_exhaust_mode = false
  try in_exhaust_mode = global.exhaust_mode != nil && global.exhaust_mode.is_active() except .. end
  if in_exhaust_mode && fan_ctrl.power_level > 0 && fan_ctrl.valve_open
    fan_ctrl.set_both(fan_ctrl.power_level)
  end
  tasmota.resp_cmnd(string.format('{"ExhaustModeMultiplier":%i}', int(m * 100)))
end)

tasmota.add_rule("ModBusReceived", def(value, trigger)
  if value == nil return end
  if value['DeviceAddress'] != 109 return end
  var fc = value['FunctionCode']
  if fc != 3 && fc != 4 return end
  var vals = nil
  try vals = value['Values'] except .. return end
  if vals == nil || size(vals) == 0 return end
  fan_ctrl.on_mao4_read(value['StartAddress'], int(vals[0]))
end)
