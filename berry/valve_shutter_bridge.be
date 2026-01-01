import string
import persist

class ValveBridge
  static var MAO4_ADDR = 109
  static var AO3_REG = 18    # Holding регистр для процентов (0-100%)
  static var COIL_REG = 18   # Coil регистр для включения канала 3
  var last_pct, last_ms, channel_enabled

  def init()
    self.last_pct = -1
    self.last_ms = 0
    self.channel_enabled = false
    tasmota.add_driver(self)
    persist.load()
    tasmota.set_timer(2000, /-> self.restore_pid())
  end

  def enable_channel(on)
    var val = on ? 1 : 0
    tasmota.cmd(string.format('MBGate {"deviceaddress":%d,"functioncode":5,"startaddress":%d,"type":"bit","count":1,"values":[%d],"tag":"valve:coil:","quiet":30,"retries":2}', self.MAO4_ADDR, self.COIL_REG, val))
    self.channel_enabled = on
  end

  def write_pct(pct)
    var p = int(pct)
    if p < 0 p = 0 end
    if p > 100 p = 100 end
    # Процентный режим: пишем 0-100 в Holding регистр 18
    tasmota.cmd(string.format('MBGate {"deviceaddress":%d,"functioncode":16,"startaddress":%d,"type":"uint16","count":1,"values":[%d],"tag":"valve:w16:","quiet":30,"retries":2}', self.MAO4_ADDR, self.AO3_REG, p))
  end

  def handle_shutter(value, trigger)
    if value == nil return end
    var p = int(value)
    if p < 0 p = 0 end
    if p > 100 p = 100 end
    var now = tasmota.millis()
    
    # Проверка на дребезг
    if self.last_pct >= 0
      var diff = p - self.last_pct
      if diff < 0 diff = -diff end
      if diff < 1 return end
      if now - self.last_ms < 120
        var latest = p
        tasmota.set_timer(120, /-> self.apply_valve(latest))
        return
      end
    end
    
    self.apply_valve(p)
    self.last_pct = p
    self.last_ms = now
  end

  def apply_valve(p)
    if p > 0
      # Включаем канал, затем устанавливаем значение и насос
      if !self.channel_enabled
        self.enable_channel(true)
      end
      tasmota.set_timer(50, /-> self.write_pct(p))
      tasmota.cmd("Power2 ON")
    else
      # Сначала ставим 0, затем выключаем канал и насос
      self.write_pct(0)
      tasmota.set_timer(50, /-> self.enable_channel(false))
      tasmota.cmd("Power2 OFF")
    end
  end

  def restore_pid()
    var sp = persist.pid_setpoint
    if sp != nil && str(sp) != "" tasmota.cmd("PidSp " + str(sp)) end
  end

end

var valve_bridge = ValveBridge()
global.valve_bridge = valve_bridge

tasmota.add_rule("Shutter1#Target", def(v, t) valve_bridge.handle_shutter(v, t) end)

tasmota.add_cmd('PidSpSave', def(cmd, idx, payload)
  if payload == nil || payload == ""
    tasmota.resp_cmnd("Usage: PidSpSave <value>")
    return
  end
  persist.pid_setpoint = str(payload)
  persist.save()
  tasmota.cmd("PidSp " + str(payload))
  tasmota.resp_cmnd_done()
end)
