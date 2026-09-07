local component = require("component")
local os = require("os")
local serialization = require("serialization")
local event = require("event")
local term = require("term")
local shell = require("shell")
local sides = require("sides")
local fs = require("filesystem")

if not component.isAvailable("br_reactor") or not component.isAvailable("modem") or
   not component.isAvailable("gpu") or not component.isAvailable("redstone") then
  io.stderr:write("Fehler: Reaktor, Modem, GPU oder Redstone-Karte fehlt am Client!\n")
  return
end

local reactor = component.getPrimary and component.getPrimary("br_reactor") or component.br_reactor
local modem = component.modem
local gpu = component.gpu
local rs = component.redstone
local PORT = 101
local SERVER_TIMEOUT = 3
local misses = 0
local guiMessage = "Bereit"
local lastGuiSignature = nil
local currentDir = shell.getWorkingDirectory() or "/"

local REDSTONE_LAMP_SIDE = "ALL"
local REDSTONE_ON = 15
local REDSTONE_OFF = 0

local REDSTONE_SIDES = {
  front = sides.front,
  back = sides.back,
  left = sides.left,
  right = sides.right,
  top = sides.top,
  bottom = sides.bottom
}

local function setLampOutput(value)
  value = tonumber(value) or REDSTONE_OFF
  if value ~= 0 then value = REDSTONE_ON end
  if REDSTONE_LAMP_SIDE == "ALL" then
    for _, side in pairs(REDSTONE_SIDES) do pcall(rs.setOutput, side, value) end
  else
    local side = REDSTONE_SIDES[string.lower(REDSTONE_LAMP_SIDE)]
    if side ~= nil then pcall(rs.setOutput, side, value) end
  end
end

modem.open(PORT)
if modem.setStrength then modem.setStrength(400) end

gpu.setResolution(60, 16)
gpu.setBackground(0x0C0F12)
gpu.setForeground(0xECF0F1)
term.clear()

local FARBE_WEISS = 0
local FARBE_ROT = 14

local function setzeSignalAufAllenSeiten(farbe, staerke)
  if not rs.setBundledOutput then return end
  for seite = 0, 5 do pcall(rs.setBundledOutput, seite, farbe, staerke) end
end

local function drawButton(x, y, w, h, text, bg, fg)
  gpu.setBackground(bg)
  gpu.fill(x, y, w, h, " ")
  gpu.setForeground(fg or 0xECF0F1)
  gpu.set(x + math.max(1, math.floor((w - #text) / 2)), y + math.floor(h / 2), text)
end

-- Backup/Restore wird direkt aus dem aktuellen Arbeitsverzeichnis gestartet.
-- Dadurch ist es egal, wo die Testlua-Dateien installiert wurden.
local function floppyCommand(command)
  local script = fs.concat(currentDir, "floppy_backup.lua")
  if not fs.exists(script) then
    guiMessage = "FEHLER: floppy_backup.lua fehlt"
    return
  end

  -- shell.execute arbeitet zuverlässiger mit dem relativen Dateinamen aus
  -- dem aktuellen Arbeitsverzeichnis als mit einem möglicherweise langen Pfad.
  local oldDir = shell.getWorkingDirectory()
  local changedDir = false
  if oldDir ~= currentDir and shell.setWorkingDirectory then
    local ok = pcall(shell.setWorkingDirectory, currentDir)
    changedDir = ok
  end

  local ok, result = pcall(shell.execute, "floppy_backup.lua " .. tostring(command))

  if changedDir and oldDir and shell.setWorkingDirectory then
    pcall(shell.setWorkingDirectory, oldDir)
  end

  if ok and result ~= false then
    if command == "backup" then
      guiMessage = "BACKUP ERFOLGREICH: TESTLUA-REACTOR"
    else
      guiMessage = "RESTORE ERFOLGREICH: TESTLUA-REACTOR"
    end
  else
    guiMessage = (command == "backup" and "BACKUP FEHLGESCHLAGEN" or "RESTORE FEHLGESCHLAGEN") ..
      " - Konsole pruefen"
  end
end

-- Die GUI wird nur bei sichtbaren Änderungen neu gezeichnet.
local function zeichneClientStatus(verbindungsStatus, detailText)
  local sichtbarerStatus = tostring(verbindungsStatus or "")
  local sichtbarerText = tostring(detailText or "")
  local sichtbareMeldung = tostring(guiMessage or "")
  local signature = sichtbarerStatus .. "|" .. sichtbarerText .. "|" .. sichtbareMeldung
  if signature == lastGuiSignature then return end
  lastGuiSignature = signature

  gpu.setBackground(0x0C0F12)
  gpu.setForeground(0xECF0F1)
  gpu.fill(1, 1, 60, 16, " ")

  gpu.setForeground(0x56B3FA)
  gpu.set(1, 1, "============================================================")
  gpu.set(1, 2, "             REAKTOR-NETZWERK CLIENT v11                    ")
  gpu.set(1, 3, "============================================================")

  gpu.setForeground(0xECF0F1)
  gpu.set(2, 5, "Status:")
  if verbindungsStatus == "ONLINE" then
    gpu.setForeground(0x2ECC71)
    gpu.set(10, 5, "[ VERBUNDEN ]")
    setLampOutput(REDSTONE_ON)
    setzeSignalAufAllenSeiten(FARBE_WEISS, 15)
    setzeSignalAufAllenSeiten(FARBE_ROT, 0)
  elseif verbindungsStatus == "SUCHEND" then
    gpu.setForeground(0xF1C40F)
    gpu.set(10, 5, "[ WARTE AUF SERVER... ]")
    setLampOutput(REDSTONE_OFF)
    setzeSignalAufAllenSeiten(FARBE_WEISS, 0)
    setzeSignalAufAllenSeiten(FARBE_ROT, 15)
  else
    gpu.setForeground(0xE74C3C)
    gpu.set(10, 5, "[ OFFLINE / DISCONNECT ]")
    setLampOutput(REDSTONE_OFF)
    setzeSignalAufAllenSeiten(FARBE_WEISS, 0)
    setzeSignalAufAllenSeiten(FARBE_ROT, 15)
  end

  gpu.setForeground(0xECF0F1)
  gpu.set(2, 7, "Info: " .. string.sub(sichtbarerText, 1, 52))
  gpu.set(2, 9, "Lampe: Redstone-Card | Seite: " .. REDSTONE_LAMP_SIDE)
  gpu.setForeground(0x00E5FF)
  gpu.set(2, 11, string.sub(sichtbareMeldung, 1, 56))
  gpu.setForeground(0x56B3FA)
  gpu.set(1, 12, "------------------------------------------------------------")

  drawButton(2, 14, 24, 2, "[ BACKUP REACTOR ]", 0x1A2332, 0xECF0F1)
  drawButton(28, 14, 24, 2, "[ RESTORE REACTOR ]", 0x1A2332, 0xECF0F1)
  gpu.setBackground(0x0C0F12)
end

local function getNumber(obj, method, fallback)
  if not obj or not obj[method] then return fallback end
  local ok, value = pcall(obj[method])
  if not ok then return fallback end
  value = tonumber(value)
  return value or fallback
end

local function getBool(obj, method, fallback)
  if not obj or not obj[method] then return fallback end
  local ok, value = pcall(obj[method])
  if not ok then return fallback end
  return not not value
end

local function getRodCount()
  local count = getNumber(reactor, "getNumberOfControlRods", 1)
  if count < 1 then count = 1 end
  return math.floor(count)
end

local function getRodLevel(index)
  if reactor.getControlRodLevel then
    local ok, value = pcall(reactor.getControlRodLevel, index)
    if ok and tonumber(value) then return tonumber(value) end
  end
  if reactor.getControlRodInsertion then
    local ok, value = pcall(reactor.getControlRodInsertion, index)
    if ok and tonumber(value) then return tonumber(value) end
  end
  return 0
end

local function setAllRods(level)
  level = math.max(0, math.min(100, tonumber(level) or 0))
  if reactor.setAllControlRodLevels then return pcall(reactor.setAllControlRodLevels, level) end
  if reactor.setAllControlRodInsertion then return pcall(reactor.setAllControlRodInsertion, level) end
  return false
end

local function setRod(index, level)
  level = math.max(0, math.min(100, tonumber(level) or 0))
  if reactor.setControlRodLevel then return pcall(reactor.setControlRodLevel, index, level) end
  if reactor.setControlRodInsertion then return pcall(reactor.setControlRodInsertion, index, level) end
  return false
end

local function applyCommand(serverBefehl, rodCount)
  if type(serverBefehl) ~= "table" then return false end
  local changed = false
  if serverBefehl.befehl == "AN" and reactor.setActive then
    changed = pcall(reactor.setActive, true)
  elseif serverBefehl.befehl == "AUS" and reactor.setActive then
    changed = pcall(reactor.setActive, false)
  elseif serverBefehl.befehl == "RODS" then
    local level = serverBefehl.rods or serverBefehl.value
    if level ~= nil then changed = setAllRods(level) end
  elseif serverBefehl.befehl == "RODS_UP" then
    changed = setAllRods(getRodLevel(0) - 5)
  elseif serverBefehl.befehl == "RODS_DOWN" then
    changed = setAllRods(getRodLevel(0) + 5)
  end

  if type(serverBefehl.rodLevels) == "table" then
    for i = 0, rodCount - 1 do
      local level = serverBefehl.rodLevels[i]
      if level ~= nil then setRod(i, level); changed = true end
    end
  elseif serverBefehl.rods ~= nil and serverBefehl.befehl ~= "RODS" then
    changed = setAllRods(serverBefehl.rods) or changed
  end
  return changed
end

zeichneClientStatus("SUCHEND", "Sende erste Datenpakete ins Netzwerk...")

while true do
  local energieAktuell = getNumber(reactor, "getEnergyStored", 0)
  local energieMax = getNumber(reactor, "getEnergyStoredMax", 10000000)
  if energieMax <= 0 then energieMax = 10000000 end
  local prozent = math.max(0, math.min(100, (energieAktuell / energieMax) * 100))
  local aktuelleStaebe = math.floor(getRodLevel(0))
  local rodCount = getRodCount()
  local fuelAmt = math.floor(getNumber(reactor, "getFuelAmount", 0))
  local wasteAmt = math.floor(getNumber(reactor, "getWasteAmount", 0))
  local maxFuel = getNumber(reactor, "getFuelAmountMax", 1000)
  if maxFuel <= 0 then maxFuel = 1000 end
  local fuelPct = math.max(0, math.min(100, (fuelAmt / maxFuel) * 100))
  local wastePct = math.max(0, math.min(100, (wasteAmt / maxFuel) * 100))

  local daten = {
    prozent = prozent,
    tempKern = math.floor(getNumber(reactor, "getFuelTemperature", 0)),
    casingTemp = math.floor(getNumber(reactor, "getCasingTemperature", 0)),
    rfProTick = math.floor(getNumber(reactor, "getEnergyProducedLastTick", 0)),
    istAktiv = getBool(reactor, "getActive", false),
    steuerstaebe = aktuelleStaebe,
    rodCount = rodCount,
    rodLevels = {},
    fuelAmt = fuelAmt,
    wasteAmt = wasteAmt,
    fuelPct = fuelPct,
    wastePct = wastePct,
    energieAktuell = energieAktuell,
    energieMax = energieMax,
    hatTurbine = false,
    turbineRPM = 0,
    turbineDampf = 0
  }

  for i = 0, rodCount - 1 do daten.rodLevels[i] = math.floor(getRodLevel(i)) end

  if component.isAvailable("br_turbine") then
    local turbine = component.getPrimary and component.getPrimary("br_turbine") or component.br_turbine
    if turbine then
      daten.hatTurbine = true
      daten.turbineRPM = math.floor(getNumber(turbine, "getRotorSpeed", 0))
      if turbine.getFluidAmount then
        daten.turbineDampf = math.floor(getNumber(turbine, "getFluidAmount", 0))
      elseif turbine.getFluidCapacity then
        daten.turbineDampf = math.floor(getNumber(turbine, "getFluidCapacity", 0))
      end
      daten.rfProTick = math.floor(getNumber(turbine, "getEnergyProducedLastTick", daten.rfProTick))
    end
  end

  modem.broadcast(PORT, serialization.serialize(daten))

  local antwort = nil
  for _ = 1, SERVER_TIMEOUT do
    local eventTyp, screenOrLocal, senderOrX, portOrY, distanceOrButton, messageOrUser = event.pull(1.0)
    if eventTyp == "modem_message" and tonumber(portOrY) == PORT and messageOrUser and tostring(messageOrUser) ~= "" then
      antwort = messageOrUser
      break
    elseif eventTyp == "touch" then
      local touchX = tonumber(senderOrX) or 0
      local touchY = tonumber(portOrY) or 0
      if touchY >= 14 and touchY <= 15 then
        if touchX >= 2 and touchX <= 25 then
          floppyCommand("backup")
          zeichneClientStatus("ONLINE", "Backup wird ausgeführt...")
        elseif touchX >= 28 and touchX <= 52 then
          floppyCommand("restore")
          zeichneClientStatus("ONLINE", "Restore wird ausgeführt...")
        end
      end
    end
  end

  if antwort then
    misses = 0
    local success, serverBefehl = pcall(serialization.unserialize, tostring(antwort))
    if success and type(serverBefehl) == "table" then
      local changed = applyCommand(serverBefehl, rodCount)
      if changed then guiMessage = "Serverbefehl ausgeführt" end
    end
    zeichneClientStatus("ONLINE", string.format("Server aktiv | %d Staebe | %d RF/t", rodCount, daten.rfProTick))
    if not getBool(reactor, "getActive", false) then setzeSignalAufAllenSeiten(FARBE_WEISS, 0) end
  else
    misses = misses + 1
    if misses >= 2 then
      if reactor.setActive and getBool(reactor, "getActive", false) then pcall(reactor.setActive, false) end
      setLampOutput(REDSTONE_OFF)
      setzeSignalAufAllenSeiten(FARBE_ROT, 15)
      zeichneClientStatus("OFFLINE", "Watchdog-Timeout! Notabschaltung aktiv.")
    else
      setLampOutput(REDSTONE_OFF)
      zeichneClientStatus("SUCHEND", "Keine Serverantwort - erneuter Versuch...")
    end
  end
end
