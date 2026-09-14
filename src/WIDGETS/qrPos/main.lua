local TELE_PATH = "/SCRIPTS/TELEMETRY"
-- EdgeTX 2.11+ exposes the firmware's own QR renderer to Lua as lvgl.qrcode.
-- When it exists the firmware encodes and draws the QR in C in a single call, so the
-- Lua encoder and the BMP file on the SD card are not needed at all. On older EdgeTX
-- and OpenTX (no lvgl API) the widget falls back to the Lua encoder + BMP path below.
local NATIVE_QR = lvgl ~= nil and lvgl.qrcode ~= nil
local STATUS_H = 16 --px reserved under the QR for the status line (native mode)

local qr = nil
local qrMutex = nil --reference to vars of active widget using qr module
local getGps = nil
local COUNT_PER_SEC = 20 --opentx seems to run at 20hz
local linkPrefixes = nil --set in create() from qrPos.lua

local myoptions = {
    { "linkType", CHOICE, 2, nil }, --populated later in create
    { "interval", VALUE, 10, 2, 60 }, --default, min, max (seconds)
    { "qrColor",   COLOR, BLUE },
    { "textColor", COLOR, DARKBLUE },
    { "qrBG",      COLOR, BLACK },
    { "bgTransp",  VALUE, 50, 0, 100 }, --BMP path only: lvgl.qrcode has no background alpha
}

local function loadModule()
    if getGps ~= nil then return end
    local module = loadfile(TELE_PATH .. "/qrPos.lua")(false)
    getGps = module.getGps
    myoptions[1][4] = module.linkLabels
    linkPrefixes = module.linkPrefixes
    if NATIVE_QR then
        Qr = nil --release the Lua encoder prototype, the firmware renders the QR
    else
        qr = module.qr:new()
    end
    module = nil
    collectgarbage()
end

local function create(zone, options)
    loadModule()
    return {
        zone = zone,
        options = options,
        pxlSize = 1,
        lastQrStr = nil,
        lastValidGps = nil,
        activeGps = nil,
        bmpObj, bmpPos = nil, nil,
        ui = nil,        --native: lvgl object refs
        statusText = nil, --native: text under the QR, nil when hidden
        dirty = false,   --native: options changed, rebuild
    }
end

local function background(vars) -- Update GPS in background
    local gpsData = getGps and getGps() or nil
    if gpsData and gpsData.valid then
        vars.lastValidGps = gpsData
    end
end

local function qrString(vars)
    local prefix = linkPrefixes[vars.options.linkType or 1] or 'geo:'
    local gps = vars.lastValidGps
    return (gps and gps.valid)
        and prefix .. string.format("%.6f,%.6f", gps.lat, gps.lon)
        or prefix .. "no gps"
end

------------------------------------------------------------------------------
-- Native path (EdgeTX 2.11+): firmware-rendered QR through lvgl.qrcode
------------------------------------------------------------------------------

local function buildNative(vars, str)
    lvgl.clear() --qrcode data is fixed at build time, so rebuild this widget's objects
    local zone = vars.zone
    local size = math.min(zone.w, zone.h - STATUS_H)
    vars.ui = lvgl.build({
        { type = "qrcode",
          x = math.floor((zone.w - size) / 2), y = math.floor((zone.h - STATUS_H - size) / 2), w = size,
          data = str,
          color = vars.options.qrColor or BLACK,
          bgColor = vars.options.qrBG or WHITE },
        { type = "label",
          x = 0, y = zone.h - STATUS_H, w = zone.w, h = STATUS_H,
          font = SMLSIZE, align = CENTER,
          color = vars.options.textColor or BLACK,
          text = function() return vars.statusText or "" end,
          visible = function() return vars.statusText ~= nil end },
    })
end

local function refreshNative(vars)
    background(vars) --gets latest gps data
    local newStr = qrString(vars)
    local interval = vars.options.interval or 10
    local activeAge = (vars.activeGps ~= nil) and ((getTime() - vars.activeGps.time) / 100) or interval + 1
    if vars.ui == nil or vars.dirty or (newStr ~= vars.lastQrStr and activeAge > interval) then
        buildNative(vars, newStr)
        vars.lastQrStr, vars.activeGps, vars.dirty = newStr, vars.lastValidGps, false
    end
    if vars.lastValidGps == nil or not vars.lastValidGps.valid then
        vars.statusText = "NO GPS"
    elseif activeAge > interval + 1 then
        vars.statusText = string.format("outdated %.0fs", activeAge)
    else
        vars.statusText = nil
    end
end

------------------------------------------------------------------------------
-- Legacy path (EdgeTX <= 2.10, OpenTX): Lua encoder streams a BMP, lcd draws it
------------------------------------------------------------------------------

function getMyQr(vars)
    return (qrMutex == nil or qrMutex == vars) and qr or nil
end

function drawBMP(qr, vars, btmPadding)
    if vars.bmpObj == nil or btmPadding ~= vars.bmpPos.btmPadding then
        if qr.bmpPath == nil then return end
        vars.bmpObj = vars.bmpObj or Bitmap.open(qr.bmpPath)
        local bmpW, bmpH = Bitmap.getSize(vars.bmpObj)
        local availW, availH = vars.zone.w, vars.zone.h - (btmPadding or 0)
        local scale = math.min(math.floor(availW / bmpW * 100), math.floor(availH / bmpH * 100))
        vars.bmpPos = {
            btmPadding = btmPadding,
            offsetX = vars.zone.x + (availW - bmpW * scale / 100) / 2,
            offsetY = vars.zone.y + (availH - bmpH * scale / 100) / 2,
            scale = scale
        }
    end
    lcd.drawBitmap(vars.bmpObj, vars.bmpPos.offsetX, vars.bmpPos.offsetY, vars.bmpPos.scale)
end

local function drawOverlayMsg(zone, text, barProgress, barMax)
    local strW, strH = lcd.sizeText(text, SMLSIZE)
    local boxW = strW + 16
    local boxH = barProgress and (strH + 14) or (strH + 6)
    local boxX = zone.x + (zone.w - boxW) / 2
    local boxY = zone.y + (zone.h - boxH) / 2
    lcd.drawFilledRectangle(boxX, boxY, boxW, boxH, WHITE)
    lcd.drawRectangle(boxX, boxY, boxW, boxH, CUSTOM_COLOR, 2)
    lcd.drawText(zone.x + zone.w/2, boxY + 3, text, CENTER + SMLSIZE + CUSTOM_COLOR)
    if barProgress and barMax then
        local barW, barX, barY = boxW - 16, boxX + 8, boxY + strH + 4
        lcd.drawRectangle(barX, barY, barW, 6)
        lcd.drawFilledRectangle(barX + 1, barY + 1, (barW - 2) * barProgress / barMax, 4, CUSTOM_COLOR)
    end
end

local function refreshLegacy(vars)
    background(vars) --gets latest gps data
    local newStr = qrString(vars)
    -- Check if we need to generate a new QR code
    local interval = (vars.options.interval or 10)
    local activeAge = (vars.activeGps ~= nil) and ((getTime() - vars.activeGps.time) / 100) or interval + 1
    local myqr = getMyQr(vars)
    if myqr and (newStr ~= vars.lastQrStr) and not qr:isRunning() and (activeAge > interval or not vars.bmpObj) then
        qrMutex = vars
        qr.fgColor, qr.bgColor, qr.bgTransp = vars.options.qrColor, vars.options.qrBG, vars.options.bgTransp
        qr:start(newStr)
        vars.lastQrStr, vars.activeGps = newStr, vars.lastValidGps
        qr.bmpPath = "/SCRIPTS/TELEMETRY/qr_temp.bmp" --enable bmp output
        print("Starting QR generation for: " .. newStr, activeAge, interval)
    end
    local underText = (activeAge > interval + 1) and string.format("outdated %.0fs", activeAge) or nil
    if underText then --draw below
        lcd.drawText(vars.zone.x + vars.zone.w/2, vars.zone.y + vars.zone.h - 15, underText, CENTER + SMLSIZE + CUSTOM_COLOR)
    end
    if myqr and qr:isRunning() then --do generation steps
        if qr:genframe() then -- Generation complete
            -- Calculate pixel size to fit in zone with padding
            vars.pxlSize = math.floor(math.min(vars.zone.w, vars.zone.h - 20) / (qr.width + 2))
            vars.bmpObj = nil --force reload bmp
            drawBMP(qr, vars) --saves context before releasing mutex
            qrMutex = nil
        end
    end
    -- Draw QR code or status
    lcd.setColor(CUSTOM_COLOR, vars.options.textColor or BLACK)
    if vars.bmpPos or qr.isvalid then -- Draw QR code, even the old one
        drawBMP(qr, vars, underText and 14 or 0)
    end
    -- now draw status overlays
    if myqr and qr:isRunning() then
        drawOverlayMsg(vars.zone, "Generating...", qr.progress or 0, 11)
    elseif vars.lastValidGps == nil or not vars.lastValidGps.valid then
        drawOverlayMsg(vars.zone, vars.lastValidGps and "Not set up" or "NO GPS")
    end
end

------------------------------------------------------------------------------

local function update(vars, newOptions)
    if vars ~= nil then
        vars.options = newOptions
        vars.activeGps = nil --force refresh
        vars.bmpObj = nil --force reload bmp
        vars.dirty = true --native: rebuild with new colors / link type
    end
end

local function refresh(vars)
    if getGps == nil then
        loadModule()
        print("QR module not initialized")
        return
    end
    if NATIVE_QR then
        refreshNative(vars)
    else
        refreshLegacy(vars)
    end
end

return {
    name = "qrLua",
    options = myoptions,
    create = create,
    update = update,
    refresh = refresh,
    background = background,
    useLvgl = NATIVE_QR, --EdgeTX 2.11+: LVGL layout, ignored by older loaders
}
