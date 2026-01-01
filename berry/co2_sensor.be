class CO2Driver
  var co2_value, co2_timestamp
  def init()
    self.co2_value = nil
    self.co2_timestamp = 0
  end
  def web_sensor()
    if self.co2_value != nil
      import string
      tasmota.web_send_decimal(string.format("{s}Датчик CO2{m}%i ppm{e}", self.co2_value))
    end
  end
  def json_append()
    if self.co2_value != nil
      import string
      tasmota.response_append(string.format(",\"CO2\":{\"CO2\":%i,\"Unit\":\"ppm\"}", self.co2_value))
    end
  end
  def update_co2(value)
    self.co2_value = value
    self.co2_timestamp = tasmota.millis()
  end
  def get_co2_value()
    return self.co2_value
  end
end

var co2_driver = CO2Driver()
global.co2_driver = co2_driver

def read_co2()
  tasmota.cmd('MBGate {"deviceaddress":1,"functioncode":3,"startaddress":2,"type":"uint16","count":1,"tag":"co2:r03:","quiet":50,"retries":2}')
end

tasmota.add_cmd('CO2Read', def(cmd, idx, payload) read_co2() tasmota.resp_cmnd_done() end)
tasmota.add_cmd('CO2Value', def(cmd, idx, payload)
  var v = co2_driver.get_co2_value()
  tasmota.resp_cmnd(v != nil ? str(v) + " ppm" : "No data")
end)

tasmota.add_rule("ModBusReceived", def(value, trigger)
  if value['DeviceAddress'] == 1 && value['FunctionCode'] == 3 && value['StartAddress'] == 2
    var vals = nil
    try vals = value['Values'] except .. as e return end
    if vals != nil && size(vals) > 0 co2_driver.update_co2(vals[0]) end
  end
end)

tasmota.add_driver(co2_driver)

def co2_timer_callback()
  read_co2()
  tasmota.set_timer(30011, co2_timer_callback, "co2_auto_read")
end

tasmota.set_timer(10000, co2_timer_callback, "co2_auto_read")
