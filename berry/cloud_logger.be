import string
import gc

class CloudLogger
  static var URL = "https://script.google.com/macros/s/AKfycbzI_zrdA6SIv-06SNIeRXZKSQN5jScEOEwjHQhqiGxw9jhlJx6ATGZI9sTjTAh_xVPF/exec"
  var dev_id, last_ms, lat, lon, city
  
  def init()
    self.dev_id = self.get_mac_id()
    self.last_ms = 0
    self.lat = ""
    self.lon = ""
    self.city = ""
    tasmota.add_driver(self)
    tasmota.set_timer(180000, /-> self.fetch_geo())
    tasmota.set_timer(300000, /-> self.auto_send())
  end
  
  def auto_send()
    self.send()
    tasmota.set_timer(3600000, /-> self.auto_send())
  end
  
  def get_mac_id()
    try
      var e = tasmota.eth()
      if e && e.contains('mac')
        var m = string.replace(e['mac'], ":", "")
        if size(m) >= 6 return "HVAC-" + m[-6..] end
      end
    except .. end
    return "HVAC-UNK"
  end
  
  def fetch_geo()
    if self.lat != "" return end
    gc.collect()
    if tasmota.get_free_heap() < 40000 return end
    try
      var w = webclient()
      w.begin("http://ip-api.com/json/?fields=lat,lon,city")
      var r = w.GET()
      if r == 200
        var s = w.get_string()
        var j = json.load(s)
        if j
          self.lat = str(j.find('lat', ''))
          self.lon = str(j.find('lon', ''))
          self.city = j.find('city', '')
        end
      end
      w.close()
    except .. end
  end
  
  def send()
    gc.collect()
    if tasmota.get_free_heap() < 35000 return end
    var js = self.json()
    if js == nil return end
    self.post(js)
  end
  
  def json()
    var fw=0,em=0,pl=0,sp=0,ep=0,bl=100,exm=false
    var ti="",hi="",to="",ho="",co="",ip=""
    var up = tasmota.millis() / 1000
    try fw = global.filter_wear.get_wear_percent() except .. end
    try em = global.error_handler.get_error_mask() except .. end
    try pl = global.fan_ctrl.power_level except .. end
    try sp = int(global.fan_ctrl.supply_pct) except .. end
    try ep = int(global.fan_ctrl.exhaust_pct) except .. end
    try bl = int(global.fan_ctrl.exhaust_mult * 100) except .. end
    try exm = global.exhaust_mode != nil && global.exhaust_mode.is_active() except .. end
    try if global.sht20_indoor ti = string.format("%.1f", global.sht20_indoor.temp_c) end except .. end
    try if global.sht20_indoor hi = string.format("%.1f", global.sht20_indoor.humi_pct) end except .. end
    try to = string.format("%.1f", global.sht20_outdoor.temp_c) except .. end
    try ho = string.format("%.1f", global.sht20_outdoor.humi_pct) except .. end
    try var c = global.co2_driver.get_co2_value() if c co = str(c) end except .. end
    try var e = tasmota.eth() if e && e.contains('ip') ip = e['ip'] end except .. end
    var pr = (em & 0x01) != 0
    var rc = (em & 0x02) != 0
    var fs = (em & 0x04) != 0
    var fe = (em & 0x08) != 0
    var pa = (em & 0x8000) != 0
    return string.format('{"d":"%s","fw":%.2f,"em":%d,"pl":%d,"sp":%d,"ep":%d,"bl":%d,"exm":%s,"ti":"%s","hi":"%s","to":"%s","ho":"%s","co":"%s","pr":%s,"fs":%s,"fe":%s,"rc":%s,"pa":%s,"ip":"%s","up":%d,"lat":"%s","lon":"%s","city":"%s"}',
      self.dev_id, fw, em, pl, sp, ep, bl, exm?"true":"false", ti, hi, to, ho, co, pr?"true":"false", fs?"true":"false", fe?"true":"false", rc?"true":"false", pa?"true":"false", ip, up, self.lat, self.lon, self.city)
  end
  
  def post(js)
    try
      var cl = webclient()
      cl.begin(self.URL)
      cl.add_header("Content-Type", "application/json")
      var r = cl.POST(js)
      cl.close()
      if r == 200 || r == 302 self.last_ms = tasmota.millis() end
    except .. end
  end
  
  def on_error_change(n, o) end
end

var cl = CloudLogger()
global.cloud_logger = cl

tasmota.add_cmd('CLS', def(c,i,p) cl.send() tasmota.resp_cmnd_done() end)
