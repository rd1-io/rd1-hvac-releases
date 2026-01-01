import json
import string

class ModbusGate
  var queue, busy, current, last_tx_ms
  static var DEFAULT_QUIET = 30
  static var TIMEOUT = 500
  static var MAX_QUEUE = 64

  def init()
    self.queue = []
    self.busy = 0
    self.current = nil
    self.last_tx_ms = 0
  end

  def send(cmd_str, tag, quiet_ms, retries, priority)
    var q = quiet_ms != nil ? quiet_ms : self.DEFAULT_QUIET
    var r = retries != nil ? retries : 2
    var prio = priority != nil ? int(priority) : 0
    var item = {"cmd":cmd_str, "tag":tag, "quiet":int(q), "retries":int(r), "attempt":0}
    if prio != 0
      var pos = (self.busy != 0 && size(self.queue) > 0) ? 1 : 0
      if pos < size(self.queue) self.queue.insert(pos, item)
      else self.queue.push(item) end
    else
      self.queue.push(item)
    end
    if self.busy == 0 self.process_next() end
  end

  def send_coalesced(cmd_str, tag, quiet_ms, retries, key)
    if key == nil
      self.send(cmd_str, tag, quiet_ms, retries, 0)
      return
    end
    var q = quiet_ms != nil ? quiet_ms : self.DEFAULT_QUIET
    var r = retries != nil ? retries : 2
    if size(self.queue) > 1
      var newq = [self.queue[0]]
      for i: 1 .. size(self.queue) - 1
        var k2 = nil
        try k2 = self.queue[i]["key"] except .. end
        if k2 == nil || k2 != key newq.push(self.queue[i]) end
      end
      self.queue = newq
    end
    self.queue.push({"cmd":cmd_str, "tag":tag, "quiet":int(q), "retries":int(r), "attempt":0, "key":key})
    if self.busy == 0 self.process_next() end
  end

  def process_next()
    if self.busy != 0 || size(self.queue) == 0 return end
    var delta = tasmota.millis() - self.last_tx_ms
    var wait = self.queue[0]["quiet"] - delta
    if wait > 0 tasmota.set_timer(wait, /-> self.do_send())
    else self.do_send() end
  end

  def do_send()
    if size(self.queue) == 0 return end
    self.busy = 1
    self.current = self.queue[0]
    tasmota.cmd(self.current["cmd"])
    self.last_tx_ms = tasmota.millis()
    tasmota.set_timer(self.TIMEOUT + 120, /-> self.on_timeout())
  end

  def on_timeout()
    if self.busy != 0 self.finish_current() end
  end

  def on_result(success)
    if self.busy == 0 || self.current == nil return end
    if success != 0
      self.finish_current()
      return
    end
    var item = self.current
    if item["attempt"] < item["retries"]
      item["attempt"] += 1
      tasmota.set_timer(item["quiet"] + 30 + item["attempt"] * 20, /-> self.do_send())
    else
      self.finish_current()
    end
  end

  def finish_current()
    if size(self.queue) > 0 self.queue.remove(0) end
    self.current = nil
    self.busy = 0
    if size(self.queue) > 0 tasmota.set_timer(10, /-> self.process_next()) end
  end
end

var modbus_gate = ModbusGate()

def mb(addr, fc, reg, cnt, vals, tag, crit)
  var cmd = string.format('ModBusSend {"deviceaddress":%d,"functioncode":%d,"startaddress":%d,"type":"uint16","count":%d}', addr, fc, reg, cnt)
  if vals != nil cmd = string.replace(cmd, "}", ',"values":[' + vals + ']}') end
  var key = string.format("%d:%d:%d", addr, fc, reg)
  if crit
    modbus_gate.send(cmd, tag, 30, 2, 1)
  else
    modbus_gate.send_coalesced(cmd, tag, 30, 2, key)
  end
end
global.mb = mb

tasmota.add_rule("RESULT", def(value, trigger)
  if value == nil return end
  try
    var send = value["ModbusSend"]
    if send != nil
      modbus_gate.on_result(send == "Done" ? 1 : 0)
      return
    end
  except .. end
  try
    if value["Command"] == "Error"
      var inp = ""
      try inp = value["Input"] except .. end
      if string.find(string.lower(str(inp)), "modbussend") >= 0 modbus_gate.on_result(0) end
    end
  except .. end
end)

def build_modbus_command(payload)
  var p = json.load(payload)
  if p == nil return {"error": "JSON parse error"} end
  var dev = p.find("deviceaddress")
  var fc = p.find("functioncode")
  var sa = p.find("startaddress")
  var typ = p.find("type")
  if dev == nil || fc == nil || sa == nil || typ == nil return {"error": "Missing required fields"} end
  var cmd = string.format('ModBusSend {"deviceaddress":%d,"functioncode":%d,"startaddress":%d,"type":"%s"', int(dev), int(fc), int(sa), typ)
  var cnt = p.find("count")
  if cnt != nil cmd += string.format(',"count":%d', int(cnt)) end
  var vals = p.find("values")
  if vals != nil
    var buf = ""
    for i: 0 .. size(vals) - 1 buf += (i > 0 ? "," : "") + str(int(vals[i])) end
    cmd += ',"values":[' + buf + ']'
  end
  var to = p.find("timeout")
  if to != nil cmd += string.format(',"timeout":%d', int(to)) end
  cmd += '}'
  var tag = p.find("tag") != nil ? str(p["tag"]) : "mbgate"
  var quiet = p.find("quiet") != nil ? int(p["quiet"]) : 30
  var retries = p.find("retries") != nil ? int(p["retries"]) : 2
  var key = string.format("%d:%d:%d", int(dev), int(fc), int(sa))
  return {"cmd_str": cmd, "tag": tag, "quiet": quiet, "retries": retries, "key": key}
end

tasmota.add_cmd('MBGate', def(cmd, idx, payload)
  var r = build_modbus_command(payload)
  if r.find("error")
    tasmota.resp_cmnd(r["error"])
    return
  end
  modbus_gate.send_coalesced(r["cmd_str"], r["tag"], r["quiet"], r["retries"], r["key"])
  tasmota.resp_cmnd_done()
end)

tasmota.add_cmd('MBGateCritical', def(cmd, idx, payload)
  var r = build_modbus_command(payload)
  if r.find("error")
    tasmota.resp_cmnd(r["error"])
    return
  end
  # Remove any queued commands with same key (prevents non-critical from overriding critical)
  var key = r["key"]
  if key != nil && size(modbus_gate.queue) > 1
    var newq = [modbus_gate.queue[0]]
    for i: 1 .. size(modbus_gate.queue) - 1
      var k2 = nil
      try k2 = modbus_gate.queue[i]["key"] except .. end
      if k2 == nil || k2 != key newq.push(modbus_gate.queue[i]) end
    end
    modbus_gate.queue = newq
  end
  modbus_gate.send(r["cmd_str"], r["tag"], r["quiet"], r["retries"], 1)
  tasmota.resp_cmnd_done()
end)

class ModbusGateStatus
  def init() tasmota.add_driver(self) end
  def web_sensor()
    var rem = size(modbus_gate.queue) - (modbus_gate.busy != 0 ? 1 : 0)
    if rem < 0 rem = 0 end
    tasmota.web_send_decimal(string.format("{s}Очередь Modbus{m}%i{e}", rem))
  end
end

var modbus_gate_status = ModbusGateStatus()
