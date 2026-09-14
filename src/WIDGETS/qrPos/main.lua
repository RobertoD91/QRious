-- QRious widget, native-LVGL prototype: the firmware renders the QR (EdgeTX 2.11+, color radios).
-- Self-contained: does not load SCRIPTS/TELEMETRY/qrPos.lua.
--
-- How this has to work in an EdgeTX widget:
--  * `useLvgl = true` (return table) puts the widget in LVGL layout mode. refresh() is then
--    called from the widget's checkEvents(), not from inside the LVGL draw callback, so it is
--    safe to create/destroy objects there. All lcd.* calls become no-ops in this mode.
--  * lvgl.qrcode() creates a new object every time it is called and nothing frees it. Calling
--    it from a 20 Hz refresh leaks one QR per cycle and crashes within seconds. Objects are
--    built once and rebuilt only when the payload or the options change, after lvgl.clear().
--  * qrcode data can only be set at build time, so a new position means a rebuild; that is
--    rate-limited by REBUILD_INTERVAL.

local myoptions = {
    { "linkType", CHOICE, 2, { "text", "native", "google", "CoMaps", "Guru" } },
    { "textColor", COLOR, DARKBLUE },
}

local linkPrefixes = { "", "geo:", "comgooglemaps://?q=", "cm://map?ll=", "GURU://" }
local STATUS_H = 16          --px reserved under the QR for the status line
local REBUILD_INTERVAL = 5   --seconds: min time between rebuilds while the position keeps changing
local OUTDATED_AFTER = 6     --seconds without a fix before the QR is flagged as outdated

local function getGps()
    local gpsfield = getFieldInfo("GPS")
    local gps = gpsfield and getValue(gpsfield.id) or nil
    if type(gps) == "table" and gps.lat ~= nil and gps.lon ~= nil then
        return { lat = gps.lat, lon = gps.lon, valid = true, time = getTime() }
    end
    return { lat = 0, lon = 0, valid = false }
end

local function create(zone, options)
    return {
        zone = zone,
        options = options,
        lastValidGps = nil,
        lastQrStr = nil,   --payload of the QR currently built
        lastBuild = 0,     --getTime() of the last build
        statusText = nil,  --text under the QR, nil when hidden
        dirty = false,     --options changed, rebuild
    }
end

local function update(vars, newOptions)
    vars.options = newOptions
    vars.dirty = true
end

local function background(vars)
    local gpsData = getGps()
    if gpsData and gpsData.valid then
        vars.lastValidGps = gpsData
    end
end

-- (Re)build this widget's LVGL objects. Coordinates are relative to the widget.
local function build(vars, str)
    lvgl.clear()
    local zone = vars.zone
    local qrSize = math.min(zone.w, zone.h - STATUS_H) - 8
    local qrX = math.floor((zone.w - qrSize) / 2)
    local qrY = math.floor((zone.h - STATUS_H - qrSize) / 2)
    lvgl.build({
        { type = "rectangle", x = qrX - 2, y = qrY - 2, w = qrSize + 4, h = qrSize + 4, color = WHITE, filled = true },
        { type = "qrcode", x = qrX, y = qrY, w = qrSize, data = str, color = BLACK, bgColor = WHITE },
        { type = "label", x = 0, y = zone.h - STATUS_H, w = zone.w, h = STATUS_H,
          font = SMLSIZE, align = CENTER, color = vars.options.textColor or BLACK,
          text = function() return vars.statusText or "" end,     --polled by the firmware
          visible = function() return vars.statusText ~= nil end },
    })
end

local function refresh(vars)
    if not (lvgl and lvgl.qrcode) then
        -- Older firmware ignores useLvgl, so lcd drawing works here
        lcd.drawText(vars.zone.x + vars.zone.w/2, vars.zone.y + vars.zone.h/2, "No LVGL QR", CENTER)
        return
    end
    background(vars)
    local prefix = linkPrefixes[vars.options.linkType or 1] or 'geo:'
    local hasGps = vars.lastValidGps and vars.lastValidGps.valid
    local newStr = hasGps
        and prefix .. string.format("%.6f,%.6f", vars.lastValidGps.lat, vars.lastValidGps.lon)
        or prefix .. "no_gps"
    local now = getTime()

    -- Rebuild at once for the first build, an options change, or the first fix replacing the
    -- placeholder; position-to-position changes are rate-limited by REBUILD_INTERVAL.
    if vars.lastQrStr == nil or vars.dirty or (hasGps and not vars.builtWithGps)
       or (newStr ~= vars.lastQrStr and (now - vars.lastBuild) / 100 >= REBUILD_INTERVAL) then
        build(vars, newStr)
        vars.lastQrStr, vars.lastBuild, vars.dirty, vars.builtWithGps = newStr, now, false, hasGps
    end

    local age = hasGps and ((now - vars.lastValidGps.time) / 100) or 0
    if not hasGps then
        vars.statusText = "NO GPS"
    elseif age > OUTDATED_AFTER then
        vars.statusText = string.format("outdated %.0fs", age)
    else
        vars.statusText = nil
    end
end

return {
    name = "qrLua",
    options = myoptions,
    create = create,
    update = update,
    refresh = refresh,
    background = background,
    useLvgl = true,
}
