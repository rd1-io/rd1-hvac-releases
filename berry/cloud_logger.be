import string
import persist

class CloudLogger
  static var SHEETS_INTERVAL_MS = 3600000
  static var MAX_RETRIES = 3
  static var DEFAULT_SHEETS_URL = "https://script.google.com/macros/s/AKfycbzlIBGwKLsQHAJeCkKh57r5wZOORLp5QqS0-994yJo4XxXpTXLV8wnMItdCd36iDGOO/exec"
  
  var sheets_url, device_id, last_sheets_send_ms, last_error_mask
  var pending_send, retry_count, enabled
  
  def init()
    persist.load()
    self.sheets_url = persist.find('cl_sheets_url', self.DEFAULT_SHEETS_URL)
    self.device_id = persist.find('cl_device_id', self.get_mac_id())
    self.last_sheets_send_ms = 0
    self.last_error_mask = 0
    self.pending_send = false
    self.retry_count = 0
    self.enabled = true
    tasmota.add_driver(self)
    tasmota.set_timer(60000, /-> self.start_periodic())
    print("[CloudLogger] Device ID: " + self.device_id)
  end
  
  def get_mac_id()
    try
      var eth = tasmota.eth()
      if eth != nil && eth.contains('mac')
        var mac = eth['mac']
        if mac != nil && mac != ''
          var clean_mac = string.replace(mac, ":", "")
          if size(clean_mac) >= 6
            return "HVAC-" + clean_mac[-6..]
          end
        end
      end
    except ..
    end
    return "HVAC-UNKNOWN"
  end
  
  def start_periodic()
    self.check_and_send()
    tasmota.set_timer(60000, /-> self.start_periodic(), "cloud_periodic")
  end
  
  def check_and_send()
    if !self.enabled return end
    var now = tasmota.millis()
    if self.sheets_url != '' && (now - self.last_sheets_send_ms > self.SHEETS_INTERVAL_MS || self.pending_send)
      self.send_to_sheets()
    end
  end
  
  def send_to_sheets()
    if self.sheets_url == '' return end
    var data = self.collect_data()
    if data == nil return end
    tasmota.set_timer(0, /-> self.http_post_sheets(data))
  end
  
  def collect_data()
    var data = {}
    data['device_id'] = self.device_id
    try data['filter_wear'] = global.filter_wear.get_wear_percent() except .. data['filter_wear'] = 0 end
    try
      var mask = global.error_handler.get_error_mask()
      data['error_mask'] = mask
      data['pressure'] = (mask & 0x01) != 0
      data['recuperator'] = (mask & 0x02) != 0
      data['filter_supply'] = (mask & 0x04) != 0
      data['filter_exhaust'] = (mask & 0x08) != 0
      data['pause'] = (mask & 0x8000) != 0
    except ..
      data['error_mask'] = 0
      data['pressure'] = false
      data['recuperator'] = false
      data['filter_supply'] = false
      data['filter_exhaust'] = false
      data['pause'] = false
    end
    try
      data['power_level'] = global.fan_ctrl.power_level
      data['supply_pct'] = int(global.fan_ctrl.supply_pct)
      data['exhaust_pct'] = int(global.fan_ctrl.exhaust_pct)
      data['balance'] = int(global.fan_ctrl.exhaust_mult * 100)
    except ..
      data['power_level'] = 0
      data['supply_pct'] = 0
      data['exhaust_pct'] = 0
      data['balance'] = 100
    end
    try data['exhaust_mode'] = global.exhaust_mode != nil && global.exhaust_mode.is_active() except .. data['exhaust_mode'] = false end
    try
      if global.sht20_indoor != nil
        data['temp_indoor'] = global.sht20_indoor.temp_c
        data['humi_indoor'] = global.sht20_indoor.humi_pct
      end
    except .. end
    try
      data['temp_outdoor'] = global.sht20_outdoor.temp_c
      data['humi_outdoor'] = global.sht20_outdoor.humi_pct
    except .. end
    try data['co2'] = global.co2_driver.get_co2_value() except .. end
    try
      var eth = tasmota.eth()
      if eth != nil && eth.contains('ip')
        var ip = eth['ip']
        data['device_ip'] = (ip != nil && ip != '0.0.0.0') ? ip : ''
      else
        data['device_ip'] = ''
      end
    except .. data['device_ip'] = '' end
    return data
  end
  
  def http_post_sheets(data)
    try
      var cl = webclient()
      cl.begin(self.sheets_url)
      cl.add_header("Content-Type", "application/json")
      var json = self.to_json(data)
      print("[CloudLogger] Sending: " + json)
      var rc = cl.POST(json)
      if rc == 200 || rc == 302
        print("[CloudLogger] OK")
        self.last_sheets_send_ms = tasmota.millis()
        self.pending_send = false
        self.retry_count = 0
      else
        print("[CloudLogger] HTTP " + str(rc))
        self.schedule_retry()
      end
      cl.close()
    except .. as e, m
      print("[CloudLogger] Error: " + str(e) + " " + str(m))
      self.schedule_retry()
    end
  end
  
  def schedule_retry()
    self.retry_count += 1
    if self.retry_count <= self.MAX_RETRIES
      self.pending_send = true
    else
      self.retry_count = 0
      self.pending_send = false
    end
  end
  
  def to_json(data)
    var parts = []
    for k: data.keys()
      var v = data[k]
      if v == nil continue end
      if type(v) == 'string'
        parts.push(string.format('"%s":"%s"', k, v))
      elif type(v) == 'bool'
        parts.push(string.format('"%s":%s', k, v ? "true" : "false"))
      elif type(v) == 'real'
        parts.push(string.format('"%s":%.2f', k, v))
      else
        parts.push(string.format('"%s":%s', k, str(v)))
      end
    end
    return "{" + parts.concat(",") + "}"
  end
  
  def set_sheets_url(url)
    self.sheets_url = url
    persist.cl_sheets_url = url
    persist.save()
  end
  
  def set_device_id(id)
    self.device_id = id
    persist.cl_device_id = id
    persist.save()
  end
  
  def test_sheets()
    self.send_to_sheets()
  end
  
  def get_status()
    var last_send = self.last_sheets_send_ms > 0 ? string.format("%d min ago", (tasmota.millis() - self.last_sheets_send_ms) / 60000) : "never"
    return string.format('{"DeviceId":"%s","LastSend":"%s","Enabled":%s}', self.device_id, last_send, self.enabled ? "true" : "false")
  end
  
  def on_error_change(new_mask, old_mask)
    self.last_error_mask = new_mask
  end
  
  def force_send()
    self.send_to_sheets()
  end
end

var cloud_logger = CloudLogger()
global.cloud_logger = cloud_logger

tasmota.add_cmd('CloudLoggerUrl', def(cmd, idx, payload)
  if payload == nil || payload == ""
    tasmota.resp_cmnd(string.format('{"CloudLoggerUrl":"%s"}', cloud_logger.sheets_url))
  else
    cloud_logger.set_sheets_url(payload)
    tasmota.resp_cmnd_done()
  end
end)

tasmota.add_cmd('CloudLoggerDeviceId', def(cmd, idx, payload)
  if payload == nil || payload == ""
    tasmota.resp_cmnd(string.format('{"CloudLoggerDeviceId":"%s"}', cloud_logger.device_id))
  else
    cloud_logger.set_device_id(payload)
    tasmota.resp_cmnd_done()
  end
end)

tasmota.add_cmd('CloudLoggerTest', def(cmd, idx, payload)
  cloud_logger.test_sheets()
  tasmota.resp_cmnd_done()
end)

tasmota.add_cmd('CloudLoggerStatus', def(cmd, idx, payload)
  tasmota.resp_cmnd(cloud_logger.get_status())
end)

tasmota.add_cmd('CloudLoggerSend', def(cmd, idx, payload)
  cloud_logger.force_send()
  tasmota.resp_cmnd_done()
end)
