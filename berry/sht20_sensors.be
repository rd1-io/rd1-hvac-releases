import string

class SHT20Driver
  var addr, label, temp_c, humi_pct, last_ms

  def init(a, lbl)
    self.addr = a
    self.label = lbl
    self.temp_c = nil
    self.humi_pct = nil
    self.last_ms = 0
  end

  def web_sensor()
    if self.temp_c != nil tasmota.web_send_decimal(string.format("{s}Температура %s{m}%.1f °C{e}", self.label, self.temp_c)) end
    if self.humi_pct != nil tasmota.web_send_decimal(string.format("{s}Влажность %s{m}%.1f %%{e}", self.label, self.humi_pct)) end
  end

  def json_append()
    if self.temp_c != nil || self.humi_pct != nil
      tasmota.response_append(string.format(',\"%sSHT20\":{\"Temperature\":%.1f,\"Humidity\":%.1f}', self.label, self.temp_c != nil ? self.temp_c : 0, self.humi_pct != nil ? self.humi_pct : 0))
    end
  end

  def update_temp(raw) self.temp_c = raw / 10.0 self.last_ms = tasmota.millis() end
  def update_humi(raw) self.humi_pct = raw / 10.0 self.last_ms = tasmota.millis() end
  def read_both()
    tasmota.cmd(string.format('MBGate {"deviceaddress":%d,"functioncode":4,"startaddress":1,"type":"uint16","count":2,"timeout":3000,"tag":"sht20:r04:","quiet":40,"retries":2}', self.addr))
  end
end

var sht20_outdoor = SHT20Driver(2, "улица")
var sht20_indoor = SHT20Driver(10, "комната")
global.sht20_outdoor = sht20_outdoor
global.sht20_indoor = sht20_indoor

tasmota.add_driver(sht20_outdoor)
tasmota.add_driver(sht20_indoor)

tasmota.add_rule("ModBusReceived", def(value, trigger)
  if value == nil return end
  var dev = value['DeviceAddress']
  var fc = value['FunctionCode']
  var sa = value['StartAddress']
  if fc != 4 return end
  var vals = nil
  try vals = value['Values'] except .. return end
  if vals == nil || size(vals) == 0 return end
  
  # Combined read: startaddress=1, count=2 -> vals[0]=temp, vals[1]=humi
  if sa == 1 && size(vals) >= 2
    if dev == 2
      sht20_outdoor.update_temp(vals[0])
      sht20_outdoor.update_humi(vals[1])
    elif dev == 10
      sht20_indoor.update_temp(vals[0])
      sht20_indoor.update_humi(vals[1])
    end
  end
end)

tasmota.add_cmd('OutdoorSHTRead', def(cmd, idx, payload)
  sht20_outdoor.read_both()
  tasmota.resp_cmnd_done()
end)

tasmota.add_cmd('IndoorSHTRead', def(cmd, idx, payload)
  sht20_indoor.read_both()
  tasmota.resp_cmnd_done()
end)

tasmota.add_cmd('OutdoorSHTValue', def(cmd, idx, payload)
  tasmota.resp_cmnd(string.format("T:%.1f C, H:%.1f %%", sht20_outdoor.temp_c != nil ? sht20_outdoor.temp_c : 0, sht20_outdoor.humi_pct != nil ? sht20_outdoor.humi_pct : 0))
end)

tasmota.add_cmd('IndoorSHTValue', def(cmd, idx, payload)
  tasmota.resp_cmnd(string.format("T:%.1f C, H:%.1f %%", sht20_indoor.temp_c != nil ? sht20_indoor.temp_c : 0, sht20_indoor.humi_pct != nil ? sht20_indoor.humi_pct : 0))
end)

def outdoor_timer() sht20_outdoor.read_both() tasmota.set_timer(119993, outdoor_timer, "sht_out") end
def indoor_timer() sht20_indoor.read_both() tasmota.set_timer(29981, indoor_timer, "sht_in") end

tasmota.set_timer(4000, outdoor_timer, "sht_out")
tasmota.set_timer(10000, indoor_timer, "sht_in")
