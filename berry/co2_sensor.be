class CO2Driver
  var co2_value, co2_timestamp
  def init()
    self.co2_value = nil
    self.co2_timestamp = 0
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
