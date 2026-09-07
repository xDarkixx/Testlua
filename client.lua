local component = require("component")
local os = require("os")
local serialization = require("serialization")
local event = require("event")
local term = require("term")

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

modem.open(PORT)
if modem.setStrength then modem.setStrength(400) end

gpu.setResolution(50, 14)
gpu.setBackground(0x0C0F12)
term.clear()

local FARBE_WEISS = 0
local FARBE_ROT = 14

local function setzeSignalAufAllenSeiten(farbe, staerke)
  if not rs.setBundledOutput then return end
  for seite = 0, 5 do
    pcall(rs.setBundledOutput, seite, farbe, staerke)
  end
end

local function zeichneClientStatus(verbindungsStatus, detailText)
  term.clear()
  gpu.setForeground(0x56B3FA)
  print("==================================================")
  print("        REAKTOR-NETZWERK CLIENT v9.2             ")
  print("==================================================")
  io.write(" Status: ")
  if verbindungsStatus == "ONLINE" then
    gpu.setForeground(0x2ECC71)
    print("[ VERBUNDEN ]")
    setzeSignalAufAllenSeiten(FARBE_WEISS, 15)
    setzeSignalAufAllenSeiten(FARBE_ROT, 0)
  elseif verbindungsStatus == "SUCHEND" then
    gpu.setForeground(0xF1C40F)
    print("[ WARTE AUF SERVER... ]")
    setzeSignalAufAllenSeiten(FARBE_WEISS, 0)
    setzeSignalAufAllenSeiten(FARBE_ROT, 15)
  else
    gpu.setForeground(0xE74C3C)
    print("[ OFFLINE / DISCONNECT ]")
    setzeSignalAufAllenSeiten(FARBE_WEISS, 0)
    setzeSignalAufAllenSeiten(FARBE_ROT, 15)
  end
  gpu.setForeground(0xECF0F1)
  print(" Info: " .. (detailText or "Initialisiere..."))
  print("==================================================")
end

local function getNumber(obj, method, fallback)
  if not obj or not obj[method] then return fallback end
  local ok, value = pcall(obj[method])
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
    return getNumber(reactor, "getControlRodLevel", 0)
  end
  if reactor.getControlRodInsertion then
    return getNumber(reactor, "getControlRodInsertion", 0)
  end
  return 0
end

local function setAllRods(level)
  level = math.max(0, math.min(100, tonumber(level) or 0))
  if reactor.setAllControlRodInsertion then
    return pcall(reactor.setAllControlRodInsertion, level)
  end
  if reactor.setAllControlRodLevels then
    return pcall(reactor.setAllControlRodLevels, level)
  end
  return false
end

local function setRod(index, level)
  level = math.max(0, math.min(100, tonumber(level) or 0))
  if reactor.setControlRodInsertion then
    return pcall(reactor.setControlRodInsertion, index, level)
  end
  if reactor.setControlRodLevel then
    return pcall(reactor.setControlRodLevel, index, level)
  end
  return false
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

  for i = 0, rodCount - 1 do
    daten.rodLevels[i] = math.floor(getRodLevel(i))
  end

  if component.isAvailable("br_turbine") then
    local turbine = component.getPrimary and component.getPrimary("br_turbine") or component.br_turbine
    if turbine then
      daten.hatTurbine = true
      daten.turbineRPM = math.floor(getNumber(turbine, "getRotorSpeed", 0))
      if turbine.getFluidAmountMax then
        daten.turbineDampf = math.floor(getNumber(turbine, "getFluidAmountMax", 0))
      elseif turbine.getFluidCapacity then
        daten.turbineDampf = math.floor(getNumber(turbine, "getFluidCapacity", 0))
      end
      daten.rfProTick = math.floor(getNumber(turbine, "getEnergyProducedLastTick", daten.rfProTick))
    end
  end

  modem.broadcast(PORT, serialization.serialize(daten))

  local antwort = nil
  for _ = 1, SERVER_TIMEOUT do
    local eventTyp, _, _, port, _, netzwerkAntwort = event.pull(1.0, "modem_message")
    if eventTyp == "modem_message" and port == PORT and netzwerkAntwort and tostring(netzwerkAntwort) ~= "" then
      antwort = netzwerkAntwort
      break
    end
  end

  if antwort then
    misses = 0
    local success, serverBefehl = pcall(serialization.unserialize, tostring(antwort))
    if success and type(serverBefehl) == "table" then
      if serverBefehl.befehl == "AN" and reactor.setActive then
        pcall(reactor.setActive, true)
      elseif serverBefehl.befehl == "AUS" and reactor.setActive then
        pcall(reactor.setActive, false)
      end

      if type(serverBefehl.rodLevels) == "table" then
        for i = 0, rodCount - 1 do
          local level = serverBefehl.rodLevels[i]
          if level ~= nil then setRod(i, level) end
        end
      elseif serverBefehl.rods ~= nil then
        setAllRods(serverBefehl.rods)
      end
    end

    zeichneClientStatus("ONLINE", string.format("Server aktiv | %d Staebe | %d RF/t", rodCount, daten.rfProTick))
    if not getBool(reactor, "getActive", false) then
      setzeSignalAufAllenSeiten(FARBE_WEISS, 0)
    end
  else
    misses = misses + 1
    if misses >= 2 then
      if reactor.setActive and getBool(reactor, "getActive", false) then
        pcall(reactor.setActive, false)
      end
      setzeSignalAufAllenSeiten(FARBE_ROT, 15)
      zeichneClientStatus("OFFLINE", "Watchdog-Timeout! Notabschaltung aktiv.")
    else
      zeichneClientStatus("SUCHEND", "Keine Serverantwort - erneuter Versuch...")
    end
  end
end
