import string

class RelayController
  static var ADDR = 140
  static var CHANNELS = 6
  var last_power1_on

  def init()
    self.last_power1_on = 0
    tasmota.add_driver(self)
  end

  def send_read_bits(start_address, count)
    if count == nil || count <= 0 return end
    tasmota.cmd(string.format('MBGate {"deviceaddress":%d,"functioncode":1,"startaddress":%d,"type":"bit","count":%d,"timeout":3000,"tag":"relay:fc1:","quiet":120,"retries":2}', self.ADDR, start_address, count))
  end

  def send_write_bit(start_address, value)
    tasmota.cmd(string.format('MBGateCritical {"deviceaddress":%d,"functioncode":5,"startaddress":%d,"type":"bit","count":1,"values":[%d],"timeout":1000,"tag":"relay:fc5:","quiet":120,"retries":2}', self.ADDR, start_address, value))
  end

  def poll_all_channels()
    self.send_read_bits(0, self.CHANNELS)
  end

  def sync_channel1_with_fan_power() end

  def verify_valve_coil(actual_coil_value)
    var expected = tasmota.get_power(0)
    var actual = (actual_coil_value != 0)
    if expected && !actual tasmota.cmd("Power1 ON")
    elif !expected && actual tasmota.cmd("Power1 OFF") end
  end

  def handle_modbus_received(value, trigger)
    if global.ota_in_progress return end  # Skip during OTA
    if value == nil || value["DeviceAddress"] != self.ADDR || value["FunctionCode"] != 1 return end
    var sa = value["StartAddress"]
    var vals = value["Values"]
    if sa == nil || vals == nil || size(vals) == 0 return end
    if size(vals) == 1 && self.CHANNELS > 1
      var mask = int(vals[0])
      for i: 0 .. self.CHANNELS - 1
        var bit = (mask >> i) & 1
        var pwr = sa + i + 1
        if pwr == 1 self.verify_valve_coil(bit)
        elif pwr >= 2 && pwr <= self.CHANNELS tasmota.cmd(string.format("Power%d %s", pwr, bit != 0 ? "ON" : "OFF")) end
      end
    else
      for i: 0 .. size(vals) - 1
        if vals[i] == nil continue end
        var pwr = sa + i + 1
        if pwr == 1 self.verify_valve_coil(vals[i])
        elif pwr >= 2 && pwr <= self.CHANNELS tasmota.cmd(string.format("Power%d %s", pwr, vals[i] != 0 ? "ON" : "OFF")) end
      end
    end
  end

  def handle_power_state(power_num, state_value)
    if power_num < 1 || power_num > self.CHANNELS return end
    var normalized = (state_value == "ON" || state_value == 1 || state_value == "1") ? 1 : 0
    if power_num == 1 self.last_power1_on = normalized end
    self.send_write_bit(power_num - 1, normalized)
  end
end

var relay_ctrl = RelayController()

tasmota.add_rule("ModBusReceived", def(v, t) relay_ctrl.handle_modbus_received(v, t) end)

for ch: 1 .. 6
  var c = ch
  tasmota.add_rule("Power" + str(ch) + "#State", def(v, t) relay_ctrl.handle_power_state(c, v) end)
end

def relay_poll_timer()
  relay_ctrl.poll_all_channels()
  tasmota.set_timer(9967, relay_poll_timer, "relay_poll")
end

tasmota.set_timer(8000, relay_poll_timer, "relay_poll")
