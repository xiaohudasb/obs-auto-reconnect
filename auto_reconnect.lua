-- ============================================================
-- OBS 采集设备自动重连脚本
-- 适用：DJI Osmo Action 6 等 USB 摄像头（UVC）
--
-- 原理：
--   1. 每秒通过 Windows SetupAPI 枚举当前插着的摄像头设备；
--   2. 自动读取 OBS 来源里绑定的设备 ID，精确判断该设备是否还在系统里
--      （不依赖设备名，换 USB 口/改名也能识别）；
--   3. 设备“从不在变成在”（重插、关机后重开）时，自动模拟
--      “在属性里把设备切到别的再切回来”，强制 DirectShow 重新打开设备。
--
-- 安装：OBS → 工具 → 脚本 → 左下角「+」→ 选择本文件
-- 注意：来源名称必须与 OBS 来源列表一致
-- ============================================================
obs = obslua

-- ---------- Windows SetupAPI（LuaJIT FFI） ----------
local ffi_ok, ffi = pcall(require, "ffi")
local sapi

if ffi_ok then
  local ok, err = pcall(function()
    ffi.cdef[[
      typedef struct _GUID {
        uint32_t Data1;
        uint16_t Data2;
        uint16_t Data3;
        uint8_t  Data4[8];
      } GUID;

      typedef struct _SP_DEVINFO_DATA {
        uint32_t  cbSize;
        GUID      ClassGuid;
        uint32_t  DevInst;
        uintptr_t Reserved;
      } SP_DEVINFO_DATA;

      void* SetupDiGetClassDevsW(const GUID* ClassGuid, const wchar_t* Enumerator,
                                 void* hwndParent, uint32_t Flags);
      int   SetupDiEnumDeviceInfo(void* DeviceInfoSet, uint32_t MemberIndex,
                                  SP_DEVINFO_DATA* DeviceInfoData);
      int   SetupDiGetDeviceRegistryPropertyW(void* DeviceInfoSet,
                                              SP_DEVINFO_DATA* DeviceInfoData,
                                              uint32_t Property,
                                              uint32_t* PropertyRegDataType,
                                              uint8_t* PropertyBuffer,
                                              uint32_t PropertyBufferSize,
                                              uint32_t* RequiredSize);
      int   SetupDiGetDeviceInstanceIdW(void* DeviceInfoSet,
                                        SP_DEVINFO_DATA* DeviceInfoData,
                                        wchar_t* DeviceInstanceId,
                                        uint32_t DeviceInstanceIdSize,
                                        uint32_t* RequiredSize);
      int   SetupDiDestroyDeviceInfoList(void* DeviceInfoSet);
    ]]
  end)
  if not ok then
    ffi_ok = false
    obs.script_log(obs.LOG_WARNING, "[自动重连] FFI 声明失败：" .. tostring(err))
  end
  if ffi_ok then
    local ok2, lib = pcall(ffi.load, "setupapi")
    if ok2 then
      sapi = lib
    else
      ffi_ok = false
      obs.script_log(obs.LOG_WARNING, "[自动重连] 加载 setupapi.dll 失败：" .. tostring(lib))
    end
  end
end

local DIGCF_PRESENT       = 0x2
local SPDRP_FRIENDLYNAME  = 0x0C

-- 设备类 GUID
local CLASS_DEFS = {
  -- Camera 类 {CA3E7AB9-B4C3-4AE6-8251-579EF933890F}
  { 0xCA3E7AB9, 0xB4C3, 0x4AE6, { 0x82, 0x51, 0x57, 0x9E, 0xF9, 0x33, 0x89, 0x0F } },
  -- Image 类 {6BDD1FC6-810F-11D0-BEC7-08002BE2092F}
  { 0x6BDD1FC6, 0x810F, 0x11D0, { 0xBE, 0xC7, 0x08, 0x00, 0x2B, 0xE2, 0x09, 0x2F } },
}
local class_guids = {}

if ffi_ok then
  for _, def in ipairs(CLASS_DEFS) do
    local g = ffi.new("GUID")
    g.Data1 = def[1]
    g.Data2 = def[2]
    g.Data3 = def[3]
    for i = 0, 7 do g.Data4[i] = def[4][i + 1] end
    class_guids[#class_guids + 1] = g
  end
end

-- UTF-16LE -> UTF-8
local function utf16_to_utf8(buf)
  local out = {}
  local i = 0
  while true do
    local lo = buf[i]
    if lo == 0 then break end
    local cp
    if lo >= 0xD800 and lo <= 0xDBFF then
      local hi = buf[i + 1] or 0
      cp = 0x10000 + (lo - 0xD800) * 0x400 + (hi - 0xDC00)
      i = i + 2
    else
      cp = lo
      i = i + 1
    end
    if cp < 0x80 then
      out[#out + 1] = string.char(cp)
    elseif cp < 0x800 then
      out[#out + 1] = string.char(0xC0 + math.floor(cp / 0x40),
                                  0x80 + cp % 0x40)
    elseif cp < 0x10000 then
      out[#out + 1] = string.char(0xE0 + math.floor(cp / 0x1000),
                                  0x80 + math.floor(cp / 0x40) % 0x40,
                                  0x80 + cp % 0x40)
    else
      out[#out + 1] = string.char(0xF0 + math.floor(cp / 0x40000),
                                  0x80 + math.floor(cp / 0x1000) % 0x40,
                                  0x80 + math.floor(cp / 0x40) % 0x40,
                                  0x80 + cp % 0x40)
    end
  end
  return table.concat(out)
end

-- 读取某个属性的字符串（UTF-16 -> UTF-8）
local function get_dev_prop(h, dev, prop, buf)
  if sapi.SetupDiGetDeviceRegistryPropertyW(
      h, dev, prop, nil,
      ffi.cast("uint8_t*", buf), 1024, nil) ~= 0 then
    local s = utf16_to_utf8(buf)
    if #s > 0 then return s end
  end
  return nil
end

-- 读取设备实例 ID（SPDRP_INSTANCEID 不是有效属性，必须用专用 API）
local function get_instance_id(h, dev, buf)
  if sapi.SetupDiGetDeviceInstanceIdW(
      h, dev, ffi.cast("wchar_t*", buf), 512, nil) ~= 0 then
    local s = utf16_to_utf8(buf)
    if #s > 0 then return s end
  end
  return nil
end

-- 返回当前存在的摄像头设备列表：{ {name=..., instance=...}, ... }
local function enum_video_devices()
  if not ffi_ok then return nil end
  local list = {}
  local seen = {}

  for _, guid in ipairs(class_guids) do
    local h = sapi.SetupDiGetClassDevsW(guid, nil, nil, DIGCF_PRESENT)
    if h ~= nil and h ~= ffi.cast("void*", -1) then
      local dev = ffi.new("SP_DEVINFO_DATA")
      local buf = ffi.new("uint16_t[512]")
      local i = 0
      while i < 256 do
        dev.cbSize = ffi.sizeof("SP_DEVINFO_DATA")
        if sapi.SetupDiEnumDeviceInfo(h, i, dev) == 0 then break end
        local inst = get_instance_id(h, dev, buf)
        if inst ~= nil then
          local key = inst:lower()
          if not seen[key] then
            seen[key] = true
            list[#list + 1] = {
              name = get_dev_prop(h, dev, SPDRP_FRIENDLYNAME, buf) or inst,
              instance = key,
            }
          end
        end
        i = i + 1
      end
      sapi.SetupDiDestroyDeviceInfoList(h)
    end
  end

  return list
end

-- 从设备 ID 中解析 VID、PID、实例号，用于跨格式匹配
--   OBS 里存的：OsmoAction6:\?\usb#22vid_2ca3&pid_8004&mi_03#227&c85d76f&0&0003#22{...}
--   PnP InstanceID：USB\VID_2CA3&PID_8004&MI_03\7&C85D76F&0&0003
--   -> vid=2ca3  pid=8004  inst=7&c85d76f&0&0003
local function parse_dev_id(s)
  s = s:lower()
  s = s:gsub("#22", "\\")  -- DirectShow 对双引号的转义，视作分隔符
  local vid = s:match("vid_([%x]+)")
  local pid = s:match("pid_([%x]+)")
  local inst = s:match("([%x]+&[%x]+&%x+&%x+)")
  return vid, pid, inst
end

-- ---------- 脚本状态 ----------
local CFG = {
  source   = "视频采集设备 2",
  keyword  = "Osmo",       -- 仅在无法读取设备 ID 时作为备用匹配
  interval = 1,
}
local auto_on        = true
local last_present   = nil
local check_timer    = nil
local restart_timer  = nil

local function log(msg)
  obs.script_log(obs.LOG_INFO, "[自动重连] " .. msg)
end

local function log_warn(msg)
  obs.script_log(obs.LOG_WARNING, "[自动重连] " .. msg)
end

-- 解析实际要操作的来源：优先用配置的名称，找不到则自动取第一个视频采集源
local function resolve_source_name()
  local src = obs.obs_get_source_by_name(CFG.source)
  if src ~= nil then
    obs.obs_source_release(src)
    return CFG.source
  end
  local fallback = nil
  local list = obs.obs_enum_sources()
  if list ~= nil then
    for _, s in ipairs(list) do
      if obs.obs_source_get_id(s) == "dshow_input" then
        fallback = obs.obs_source_get_name(s)
        break
      end
    end
    obs.source_list_release(list)
  end
  return fallback
end

-- 读取 OBS 来源里保存的设备 ID
local function source_device_id()
  local name = resolve_source_name()
  if name == nil then return nil end
  local src = obs.obs_get_source_by_name(name)
  if src == nil then return nil end
  local st = obs.obs_source_get_settings(src)
  local vid = obs.obs_data_get_string(st, "video_device_id")
  obs.obs_data_release(st)
  obs.obs_source_release(src)
  if vid == nil or vid == "" then return nil end
  return vid
end

-- ---------- 核心动作：模拟“切到别的设备再切回来” ----------
local function reconnect_now(reason)
  local name = resolve_source_name()
  if name == nil then
    log_warn("找不到视频采集源，请检查脚本设置里的“视频采集源”")
    return
  end
  local src = obs.obs_get_source_by_name(name)

  local st = obs.obs_source_get_settings(src)
  local vid = obs.obs_data_get_string(st, "video_device_id")

  if vid == nil or vid == "" then
    obs.obs_data_release(st)
    obs.obs_source_release(src)
    log_warn("来源里读不到设备 ID，无法自动切换设备")
    return
  end

  log("重新打开采集设备" .. (reason or ""))

  -- 第一步：先把设备 ID 置空（相当于在下拉框里选了“无设备”）
  obs.obs_data_set_string(st, "video_device_id", "")
  obs.obs_source_update(src, st)
  obs.obs_data_release(st)
  obs.obs_source_release(src)

  -- 第二步：400ms 后把原设备 ID 设回去（相当于重新选中原设备）
  if restart_timer ~= nil then
    obs.timer_remove(restart_timer)
  end
  restart_timer = function()
    obs.timer_remove(restart_timer)
    restart_timer = nil
    local s = obs.obs_get_source_by_name(name)
    if s ~= nil then
      local sst = obs.obs_source_get_settings(s)
      obs.obs_data_set_string(sst, "video_device_id", vid)
      obs.obs_source_update(s, sst)
      obs.obs_data_release(sst)
      obs.obs_source_release(s)
      log("设备已重新选中")
    end
  end
  obs.timer_add(restart_timer, 400)
end

-- ---------- 每秒检测 ----------
local function tick()
  if not auto_on then return end
  local devices = enum_video_devices()
  if devices == nil then return end

  local devid = source_device_id()
  local present = false
  local matched = nil

  if devid ~= nil then
    -- 首选用来源里绑定的设备 ID 精确匹配（VID + PID + 实例号）
    local v_vid, v_pid, v_inst = parse_dev_id(devid)
    if v_vid and v_pid and v_inst then
      for _, d in ipairs(devices) do
        local d_vid, d_pid, d_inst = parse_dev_id(d.instance)
        if d_vid == v_vid and d_pid == v_pid and d_inst == v_inst then
          present = true
          matched = d.name
          break
        end
      end
    end
  end

  if not present and #CFG.keyword > 0 then
    -- 备用：设备名关键字
    local key = CFG.keyword:lower()
    for _, d in ipairs(devices) do
      if d.name:lower():find(key, 1, true) then
        present = true
        matched = d.name
        break
      end
    end
  end

  if last_present == nil then
    last_present = present
    local shown = {}
    for _, d in ipairs(devices) do shown[#shown + 1] = d.name end
    local list = (#shown > 0) and table.concat(shown, "、") or "（无）"
    if present then
      log("已检测到设备「" .. matched .. "」")
    else
      log("当前视频设备：" .. list .. "；等待目标设备接入…")
    end
    return
  end

  if present and not last_present then
    log("设备重新接入：「" .. matched .. "」，自动重连中…")
    reconnect_now("（设备重新接入）")
  elseif not present and last_present then
    log("设备已断开，等待重新接入…")
  end

  last_present = present
end

-- ---------- OBS 脚本接口 ----------
function script_description()
  return "USB 视频采集设备（如 DJI Osmo Action 6）重新接入后自动重连 OBS 来源，" ..
         "无需手动在属性里切换设备。"
end

function script_properties()
  local props = obs.obs_properties_create()

  local p = obs.obs_properties_add_list(props, "source",
    "视频采集源（OBS 来源列表里的摄像头来源）",
    obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
  local sources = obs.obs_enum_sources()
  if sources ~= nil then
    for _, src in ipairs(sources) do
      if obs.obs_source_get_id(src) == "dshow_input" then
        local name = obs.obs_source_get_name(src)
        obs.obs_property_list_add_string(p, name, name)
      end
    end
    obs.source_list_release(sources)
  end

  obs.obs_properties_add_text(props, "keyword", "备用设备名关键字（可留空）",
                              obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_int(props, "interval", "检查间隔（秒）", 1, 30, 1)
  obs.obs_properties_add_bool(props, "auto", "启用自动重连")
  obs.obs_properties_add_button(props, "reconnect_now", "立即重连一次",
    function()
      reconnect_now("（手动触发）")
      return false
    end)

  return props
end

function script_defaults(settings)
  obs.obs_data_set_default_string(settings, "source", "视频采集设备 2")
  obs.obs_data_set_default_string(settings, "keyword", "Osmo")
  obs.obs_data_set_default_int(settings, "interval", 1)
  obs.obs_data_set_default_bool(settings, "auto", true)
end

function script_update(settings)
  CFG.source   = obs.obs_data_get_string(settings, "source")
  CFG.keyword  = obs.obs_data_get_string(settings, "keyword")
  CFG.interval = obs.obs_data_get_int(settings, "interval")
  auto_on      = obs.obs_data_get_bool(settings, "auto")

  if CFG.source == "" then CFG.source = "视频采集设备 2" end
  if CFG.interval < 1 then CFG.interval = 1 end

  local resolved = resolve_source_name()
  if resolved == nil then
    log_warn("当前没有找到视频采集源，请添加摄像头来源")
  elseif resolved ~= CFG.source then
    log("未找到「" .. CFG.source .. "」，自动使用「" .. resolved .. "」")
  end

  if check_timer ~= nil then
    obs.timer_remove(check_timer)
    check_timer = nil
  end
  check_timer = tick
  obs.timer_add(check_timer, CFG.interval * 1000)
end

function script_load(settings)
  if not ffi_ok then
    log_warn("LuaJIT FFI 不可用：自动检测已关闭，仍可用「立即重连一次」按钮")
  end
end

function script_unload()
  if check_timer ~= nil then
    obs.timer_remove(check_timer)
    check_timer = nil
  end
  if restart_timer ~= nil then
    obs.timer_remove(restart_timer)
    restart_timer = nil
  end
end