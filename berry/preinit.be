def init_complete() end

def set_exhaust_zero()
  tasmota.cmd('ModBusSend {"deviceaddress":109,"functioncode":16,"startaddress":17,"type":"uint16","count":1,"values":[0]}')
  tasmota.set_timer(500, init_complete)
end

def set_supply_zero()
  tasmota.cmd('ModBusSend {"deviceaddress":109,"functioncode":16,"startaddress":16,"type":"uint16","count":1,"values":[0]}')
  tasmota.set_timer(500, set_exhaust_zero)
end

def enable_exhaust_channel()
  tasmota.cmd('ModBusSend {"deviceaddress":109,"functioncode":5,"startaddress":17,"type":"bit","count":1,"values":[1]}')
  tasmota.set_timer(500, set_supply_zero)
end

def enable_supply_channel()
  tasmota.cmd('ModBusSend {"deviceaddress":109,"functioncode":5,"startaddress":16,"type":"bit","count":1,"values":[1]}')
  tasmota.set_timer(500, enable_exhaust_channel)
end

tasmota.set_timer(2000, enable_supply_channel)
