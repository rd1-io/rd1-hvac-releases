# Cloud Logger Module for HVAC System
# Sends data to Google Sheets and Telegram notifications
#
# Commands:
#   CloudLoggerUrl <url>       - Set Google Apps Script URL
#   CloudLoggerTgToken <token> - Set Telegram bot token
#   CloudLoggerTgChat <id>     - Set Telegram chat ID
#   CloudLoggerTest            - Send test data to Google Sheets
#   CloudLoggerTgTest          - Send test message to Telegram
#   CloudLoggerStatus          - Show current configuration
#   CloudLoggerSend            - Force send current data

import string
import persist
import webclient

class CloudLogger
  static var SHEETS_INTERVAL_MS = 3600000   # Send to sheets every hour
  static var RETRY_INTERVAL_MS = 300000     # Retry failed sends every 5 min
  static var MAX_RETRIES = 3
  
  var sheets_url          # Google Apps Script URL
  var tg_token            # Telegram bot token
  var tg_chat_id          # Telegram chat ID
  var last_sheets_send_ms # Last successful send to sheets
  var last_error_mask     # Last error mask sent to Telegram
  var pending_send        # Flag for pending send
  var retry_count         # Current retry count
  var enabled             # Module enabled flag
  
  def init()
    persist.load()
    self.sheets_url = persist.find('cl_sheets_url', '')
    self.tg_token = persist.find('cl_tg_token', '')
    self.tg_chat_id = persist.find('cl_tg_chat', '')
    self.last_sheets_send_ms = 0
    self.last_error_mask = 0
    self.pending_send = false
    self.retry_count = 0
    self.enabled = true
    
    tasmota.add_driver(self)
    
    # Start periodic tasks after 60 seconds (let other modules initialize)
    tasmota.set_timer(60000, /-> self.start_periodic())
    
    print("[CloudLogger] Initialized")
    if self.sheets_url != ''
      print(string.format("[CloudLogger] Sheets URL: %s...", self.sheets_url[0..50]))
    end
    if self.tg_token != ''
      print("[CloudLogger] Telegram configured")
    end
  end
  
  def start_periodic()
    self.check_and_send()
    tasmota.set_timer(60000, /-> self.start_periodic(), "cloud_periodic")
  end
  
  def check_and_send()
    if !self.enabled return end
    
    var now = tasmota.millis()
    
    # Check if it's time to send to sheets
    if self.sheets_url != '' && (now - self.last_sheets_send_ms > self.SHEETS_INTERVAL_MS || self.pending_send)
      self.send_to_sheets()
    end
    
    # Check for error changes (for Telegram)
    self.check_error_changes()
  end
  
  def check_error_changes()
    if self.tg_token == '' || self.tg_chat_id == '' return end
    
    var current_mask = 0
    try
      current_mask = global.error_handler.get_error_mask()
    except ..
      return
    end
    
    if current_mask != self.last_error_mask
      var old_mask = self.last_error_mask
      self.last_error_mask = current_mask
      
      # Determine what changed
      var new_errors = current_mask & (current_mask ^ old_mask)
      var cleared_errors = old_mask & (current_mask ^ old_mask)
      
      if new_errors != 0
        self.send_error_notification(new_errors, true)
      end
      if cleared_errors != 0
        self.send_error_notification(cleared_errors, false)
      end
    end
  end
  
  def get_error_name(bit)
    if bit == 0 return "Давление (MAO4)" end
    if bit == 1 return "Рекуператор" end
    if bit == 2 return "Приточный фильтр" end
    if bit == 3 return "Вытяжной фильтр" end
    if bit == 15 return "Пауза" end
    return string.format("Ошибка %d", bit)
  end
  
  def send_error_notification(mask, is_error)
    if self.tg_token == '' || self.tg_chat_id == '' return end
    
    var emoji = is_error ? "⚠️" : "✅"
    var status_emoji = is_error ? "🔴" : "🟢"
    var status_text = is_error ? "ОШИБКА" : "СБРОШЕНО"
    var header = is_error ? "HVAC ОШИБКА" : "HVAC ОШИБКА СБРОШЕНА"
    
    var errors = []
    for bit: 0..15
      if (mask & (1 << bit)) != 0
        errors.push(self.get_error_name(bit))
      end
    end
    
    if size(errors) == 0 return end
    
    var time_str = tasmota.strftime("%Y-%m-%d %H:%M:%S", tasmota.rtc()['local'])
    
    var msg = string.format("%s %s\n\n", emoji, header)
    for err: errors
      msg += string.format("%s %s\n", status_emoji, err)
    end
    msg += string.format("\nВремя: %s", time_str)
    
    self.send_telegram(msg)
  end
  
  def send_telegram(message)
    if self.tg_token == '' || self.tg_chat_id == '' 
      print("[CloudLogger] Telegram not configured")
      return 
    end
    
    var url = string.format(
      "https://api.telegram.org/bot%s/sendMessage?chat_id=%s&text=%s&parse_mode=HTML",
      self.tg_token,
      self.tg_chat_id,
      self.url_encode(message)
    )
    
    # Use async HTTP request
    tasmota.set_timer(0, /-> self.http_get(url, "telegram"))
  end
  
  def http_get(url, tag)
    try
      var cl = webclient()
      cl.begin(url)
      var rc = cl.GET()
      if rc == 200
        print(string.format("[CloudLogger] %s: OK", tag))
      else
        print(string.format("[CloudLogger] %s: HTTP %d", tag, rc))
      end
      cl.close()
    except .. as e, m
      print(string.format("[CloudLogger] %s error: %s %s", tag, e, m))
    end
  end
  
  def send_to_sheets()
    if self.sheets_url == ''
      print("[CloudLogger] Sheets URL not configured")
      return
    end
    
    # Collect data
    var data = self.collect_data()
    if data == nil return end
    
    # Send async
    tasmota.set_timer(0, /-> self.http_post_sheets(data))
  end
  
  def collect_data()
    var data = {}
    
    # Filter wear
    try
      data['filter_wear'] = global.filter_wear.get_wear_percent()
    except ..
      data['filter_wear'] = 0
    end
    
    # Errors
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
    
    # Device IP
    try
      var ip = tasmota.wifi()['ip']
      if ip == nil
        ip = tasmota.eth()['ip']
      end
      data['device_ip'] = ip != nil ? ip : ''
    except ..
      data['device_ip'] = ''
    end
    
    return data
  end
  
  def http_post_sheets(data)
    try
      var cl = webclient()
      cl.begin(self.sheets_url)
      cl.add_header("Content-Type", "application/json")
      
      var json = self.to_json(data)
      var rc = cl.POST(json)
      
      if rc == 200 || rc == 302
        print("[CloudLogger] Sheets: OK")
        self.last_sheets_send_ms = tasmota.millis()
        self.pending_send = false
        self.retry_count = 0
      else
        print(string.format("[CloudLogger] Sheets: HTTP %d", rc))
        self.schedule_retry()
      end
      cl.close()
    except .. as e, m
      print(string.format("[CloudLogger] Sheets error: %s %s", e, m))
      self.schedule_retry()
    end
  end
  
  def schedule_retry()
    self.retry_count += 1
    if self.retry_count <= self.MAX_RETRIES
      self.pending_send = true
      print(string.format("[CloudLogger] Will retry (%d/%d)", self.retry_count, self.MAX_RETRIES))
    else
      print("[CloudLogger] Max retries reached, will try next cycle")
      self.retry_count = 0
      self.pending_send = false
    end
  end
  
  def to_json(data)
    var parts = []
    for k: data.keys()
      var v = data[k]
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
  
  def url_encode(s)
    var result = ""
    for i: 0 .. size(s) - 1
      var c = s[i]
      var code = c[0]  # Get ASCII code
      if (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || (code >= 48 && code <= 57) || c == '-' || c == '_' || c == '.' || c == '~'
        result += c
      elif c == ' '
        result += "%20"
      else
        result += string.format("%%%02X", code)
      end
    end
    return result
  end
  
  def set_sheets_url(url)
    self.sheets_url = url
    persist.cl_sheets_url = url
    persist.save()
    print(string.format("[CloudLogger] Sheets URL set: %s", url))
  end
  
  def set_tg_token(token)
    self.tg_token = token
    persist.cl_tg_token = token
    persist.save()
    print("[CloudLogger] Telegram token set")
  end
  
  def set_tg_chat(chat_id)
    self.tg_chat_id = chat_id
    persist.cl_tg_chat = chat_id
    persist.save()
    print(string.format("[CloudLogger] Telegram chat ID set: %s", chat_id))
  end
  
  def test_sheets()
    print("[CloudLogger] Testing Sheets...")
    self.send_to_sheets()
  end
  
  def test_telegram()
    if self.tg_token == '' || self.tg_chat_id == ''
      print("[CloudLogger] Telegram not configured")
      return
    end
    print("[CloudLogger] Testing Telegram...")
    var time_str = tasmota.strftime("%Y-%m-%d %H:%M:%S", tasmota.rtc()['local'])
    var msg = string.format("🔔 HVAC Test Message\n\nТестовое сообщение от вентиляционной системы.\nВремя: %s", time_str)
    self.send_telegram(msg)
  end
  
  def get_status()
    var sheets_ok = self.sheets_url != '' ? "configured" : "not set"
    var tg_ok = (self.tg_token != '' && self.tg_chat_id != '') ? "configured" : "not set"
    var last_send = self.last_sheets_send_ms > 0 ? string.format("%d min ago", (tasmota.millis() - self.last_sheets_send_ms) / 60000) : "never"
    return string.format('{"Sheets":"%s","Telegram":"%s","LastSend":"%s","Enabled":%s}', 
      sheets_ok, tg_ok, last_send, self.enabled ? "true" : "false")
  end
  
  # Called by error_handler when error state changes
  def on_error_change(new_mask, old_mask)
    if self.tg_token == '' || self.tg_chat_id == '' return end
    
    var new_errors = new_mask & (new_mask ^ old_mask)
    var cleared_errors = old_mask & (new_mask ^ old_mask)
    
    if new_errors != 0
      self.send_error_notification(new_errors, true)
    end
    if cleared_errors != 0
      self.send_error_notification(cleared_errors, false)
    end
    
    self.last_error_mask = new_mask
  end
  
  # Force send current data
  def force_send()
    self.send_to_sheets()
  end
end

var cloud_logger = CloudLogger()
global.cloud_logger = cloud_logger

# Commands
tasmota.add_cmd('CloudLoggerUrl', def(cmd, idx, payload)
  if payload == nil || payload == ""
    tasmota.resp_cmnd(string.format('{"CloudLoggerUrl":"%s"}', cloud_logger.sheets_url))
  else
    cloud_logger.set_sheets_url(payload)
    tasmota.resp_cmnd_done()
  end
end)

tasmota.add_cmd('CloudLoggerTgToken', def(cmd, idx, payload)
  if payload == nil || payload == ""
    tasmota.resp_cmnd('{"CloudLoggerTgToken":"***"}')
  else
    cloud_logger.set_tg_token(payload)
    tasmota.resp_cmnd_done()
  end
end)

tasmota.add_cmd('CloudLoggerTgChat', def(cmd, idx, payload)
  if payload == nil || payload == ""
    tasmota.resp_cmnd(string.format('{"CloudLoggerTgChat":"%s"}', cloud_logger.tg_chat_id))
  else
    cloud_logger.set_tg_chat(payload)
    tasmota.resp_cmnd_done()
  end
end)

tasmota.add_cmd('CloudLoggerTest', def(cmd, idx, payload)
  cloud_logger.test_sheets()
  tasmota.resp_cmnd_done()
end)

tasmota.add_cmd('CloudLoggerTgTest', def(cmd, idx, payload)
  cloud_logger.test_telegram()
  tasmota.resp_cmnd_done()
end)

tasmota.add_cmd('CloudLoggerStatus', def(cmd, idx, payload)
  tasmota.resp_cmnd(cloud_logger.get_status())
end)

tasmota.add_cmd('CloudLoggerSend', def(cmd, idx, payload)
  cloud_logger.force_send()
  tasmota.resp_cmnd_done()
end)

