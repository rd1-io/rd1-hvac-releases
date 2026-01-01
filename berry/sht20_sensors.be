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

def outdoor_timer() sht20_outdoor.read_both() tasmota.set_timer(119993, outdoor_timer, "sht_out") end
def indoor_timer() sht20_indoor.read_both() tasmota.set_timer(29981, indoor_timer, "sht_in") end

tasmota.set_timer(4000, outdoor_timer, "sht_out")
tasmota.set_timer(10000, indoor_timer, "sht_in")
