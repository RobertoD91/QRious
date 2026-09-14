-- Smoke test for src/WIDGETS/qrPos/main.lua with a mocked EdgeTX API.
--
--   lua test/widget_smoke.lua native   # EdgeTX 2.11+: lvgl.qrcode available, useLvgl layout
--   lua test/widget_smoke.lua legacy   # EdgeTX <= 2.10 / OpenTX: Lua encoder + BMP + lcd
--
-- It cannot prove the radio renders correctly; it proves the widget lifecycle runs
-- without Lua errors, calls the right firmware API for the mode, and generates the
-- expected QR payload as the GPS fix, time and options change.

local mode = arg[1] or "native"
local ROOT = (arg[0]:match("^(.*)/test/[^/]+$") or ".")
local WORK = os.getenv("TMPDIR") or "/tmp"
local failures = 0
local function check(cond, msg)
    if not cond then failures = failures + 1; print("FAIL: " .. msg) else print("ok: " .. msg) end
end

------------------------------------------------------------------------------
-- Mocked EdgeTX environment
------------------------------------------------------------------------------
bit32 = { band = function(a, b) return a & b end, bor = function(a, b) return a | b end,
          bxor = function(a, b) return a ~ b end, bnot = function(a) return ~a end,
          rshift = function(a, n) return a >> n end, lshift = function(a, n) return a << n end }
CHOICE, VALUE, COLOR, BOOL = 1, 2, 3, 4
BLUE, DARKBLUE, BLACK, WHITE, CUSTOM_COLOR = 0x8001, 0x8002, 0x8003, 0x8004, 0x8005
SMLSIZE, CENTER, ERASE, SOLID, FORCE = 0x10, 0x20, 0x40, 0x80, 0x100
LCD_W, LCD_H = 480, 272

local clock = 0            -- getTime() in 10ms ticks
local gpsValue = nil       -- what getValue("GPS") returns
function getTime() return clock end
function getUsage() return 0 end
function getFieldInfo(name) return name == "GPS" and { id = 1 } or nil end
function getValue(id) return gpsValue end

local lcdCalls = 0
lcd = setmetatable({}, { __index = function(t, k)
    return function(...) lcdCalls = lcdCalls + 1; if k == "sizeText" then return 40, 10 end end
end })
local bitmapOpens = 0
Bitmap = {
    open = function(path) bitmapOpens = bitmapOpens + 1; return { path = path } end,
    getSize = function(b) return 35, 35 end,
}

-- The widget loads the engine from the SD-card path and the engine writes its BMP
-- there too; redirect both to the repo / a temp dir.
local realLoadfile, realOpen = loadfile, io.open
function loadfile(path)
    return realLoadfile((path:gsub("^/SCRIPTS/TELEMETRY", ROOT .. "/src/SCRIPTS/TELEMETRY")))
end
io.open = function(path, m) return realOpen((path:gsub("^/SCRIPTS/TELEMETRY", WORK)), m) end
io.write = function(f, data) return f:write(data) end -- radio-style io.write(file, data)

local built = {}          -- every lvgl.build() call: list of object tables
if mode == "native" then
    lvgl = {
        qrcode = function() end, -- presence is what the widget probes
        clear = function() built.cleared = (built.cleared or 0) + 1 end,
        build = function(objs)
            for _, o in ipairs(objs) do
                assert(type(o.type) == "string", "lvgl object without type")
                assert(o.x and o.y, o.type .. " without x/y")
                if o.type == "qrcode" then
                    assert(type(o.data) == "string" and #o.data > 0, "qrcode without data")
                    assert(type(o.w) == "number" and o.w > 0, "qrcode without size")
                    assert(type(o.color) == "number" and type(o.bgColor) == "number", "qrcode colors must be LcdFlags numbers")
                elseif o.type == "label" then
                    assert(type(o.text) == "string" or type(o.text) == "function", "label without text")
                    if type(o.text) == "function" then assert(type(o.text()) == "string", "label text fn must return string") end
                    if o.visible then assert(type(o.visible()) == "boolean", "visible fn must return boolean") end
                end
            end
            built[#built + 1] = objs
            return {}
        end,
    }
end

------------------------------------------------------------------------------
-- Drive the widget
------------------------------------------------------------------------------
local widget = loadfile(ROOT .. "/src/WIDGETS/qrPos/main.lua")()
check(widget.create and widget.refresh and widget.update and widget.background, "widget table complete")
check((widget.useLvgl == true) == (mode == "native"), "useLvgl flag matches mode")

local zone = { x = 0, y = 0, w = 240, h = 160, xabs = 0, yabs = 0 }
local options = { linkType = 2, interval = 10, qrColor = BLUE, textColor = DARKBLUE, qrBG = BLACK, bgTransp = 50 }
local vars = widget.create(zone, options)
check(type(vars) == "table", "create returns vars")
check(#widget.options[1][4] == 5, "link type choice labels filled from engine")

local function tick(n)
    for _ = 1, n do clock = clock + 5; widget.refresh(vars) end
end

local function lastQrData()
    local objs = built[#built]
    if not objs then return nil end
    for _, o in ipairs(objs) do if o.type == "qrcode" then return o.data end end
end

-- 1. No GPS sensor value yet
tick(3)
if mode == "native" then
    check(lastQrData() == "geo:no gps", "native: initial build uses 'no gps' payload")
    check(vars.statusText == "NO GPS", "native: status shows NO GPS")
end

-- 2. First fix
gpsValue = { lat = 37.87133, lon = -122.3175 }
tick(30) -- 1.5 s
if mode == "native" then
    check(lastQrData() == "geo:37.871330,-122.317500", "native: rebuilt with first fix")
    check(vars.statusText == nil, "native: no status text with a fresh QR")
end

-- 3. Position changes but interval (10 s) not elapsed: no rebuild yet
local buildsBefore = #built
gpsValue = { lat = 37.9, lon = -122.3 }
tick(20) -- +1 s
if mode == "native" then check(#built == buildsBefore, "native: respects interval before rebuilding") end

-- 4. Interval elapsed: rebuild with the new position
tick(300) -- +15 s
if mode == "native" then
    check(lastQrData() == "geo:37.900000,-122.300000", "native: rebuilt after interval")
end

-- 5. Options change: link type + colors -> rebuild with new prefix
widget.update(vars, { linkType = 3, interval = 10, qrColor = WHITE, textColor = BLUE, qrBG = BLACK, bgTransp = 0 })
tick(2)
if mode == "native" then
    check(lastQrData() == "comgooglemaps://?q=37.900000,-122.300000", "native: options change rebuilds with new prefix")
    local objs = built[#built]
    check(objs[1].color == WHITE and objs[1].bgColor == BLACK, "native: new colors applied")
end

-- 6. Fix lost: last good position is kept, status says outdated once stale
gpsValue = nil
tick(400) -- +20 s
check(vars.lastValidGps and vars.lastValidGps.lat == 37.9, "last valid fix survives losing telemetry")
if mode == "native" then
    check(vars.statusText and vars.statusText:match("^outdated %d+s$"), "native: outdated status text (" .. tostring(vars.statusText) .. ")")
end

-- 7. background() while widget not shown keeps polling
gpsValue = { lat = -33.9, lon = 151.2 }
widget.background(vars)
check(vars.lastValidGps.lat == -33.9, "background() updates last fix")

------------------------------------------------------------------------------
if mode == "native" then
    check(lcdCalls == 0, "native: never draws with lcd.* (no-ops in LVGL layout)")
    check(bitmapOpens == 0, "native: never touches the BMP path")
    check(Qr == nil, "native: Lua encoder prototype released")
else
    tick(200) -- let the encoder finish and the BMP be drawn
    check(bitmapOpens > 0, "legacy: BMP generated and opened")
    check(lcdCalls > 0, "legacy: draws with lcd.*")
    check(built[1] == nil, "legacy: lvgl never used")
end

print(string.format("\n%s mode: %d failure(s)", mode, failures))
os.exit(failures == 0 and 0 or 1)
