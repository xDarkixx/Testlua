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
  print("        REAKTOR-NETZWERK CLIENT v9.1             ")
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

zeichneClientStatus("SUCHEND", "Sende erste Datenpakete ins Netzwerk...")

while true do
  local energieAktuell = getNumber(reactor, "getEnergyStored", 0)
  local energieMax = getNumber(reactor, "getEnergyStoredMax", 10000000)
  if energieMax <= 0 then energieMax = 10000000 end
  local prozent = math.max(0, math.min(100, (energieAktuell / energieMax) * 100))

  local aktuelleStaebe = math.floor(getNumber(reactor, "getControlRodInsertion", 0))
  local fuelAmt = math.floor(getNumber(reactor, "getFuelAmount", 0))
  local wasteAmt = math.floor(getNumber(reactor, "getWasteAmount", 0))
  local maxFuel = getNumber(reactor, "getFuelAmountMax", 1000)
  if maxFuel <= 0 then maxFuel = 1000 end

  local fuelPct = math.max(0, math.min(100, (fuelAmt / maxFuel) * 100))
  local wastePct = math.max(0, math.min(100, (wasteAmt / maxFuel) * 100))

  local daten = {
    prozent = prozent,
    tempKern = math.floor(getNumber(reactor, "getFuelTemperature", 0)),
    rfProTick = math.floor(getNumber(reactor, "getEnergyProducedLastTick", 0)),
    istAktiv = getBool(reactor, "getActive", false),
    steuerstaebe = aktuelleStaebe,
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

      if serverBefehl.rods ~= nil and reactor.setAllControlRodInsertion then
        local rods = math.max(0, math.min(100, tonumber(serverBefehl.rods) or 0))
        pcall(reactor.setAllControlRodInsertion, rods)
      end
    end

    zeichneClientStatus("ONLINE", string.format("Server aktiv | Leistung: %d RF/t", daten.rfProTick))
    if not getBool(reactor, "getActive", false) then
      setzeSignalAufAllenSeiten(FARBE_WEISS, 0)
    end
  else
    misses = misses + 1
    if misses >= 2 then
      if reactor.setActive and getBool(reactor, "getActive", false) then
        pcall(reactor.setActive, false)
      end
      zeichneClientStatus("OFFLINE", "Watchdog-Timeout! Notabschaltung aktiv.")
      for i = 1, 2 do
        setzeSignalAufAllenSeiten(FARBE_ROT, 15)
        os.sleep(0.20)
        setzeSignalAufAllenSeiten(FARBE_ROT, 0)
        os.sleep(0.20)
      end
    else
      zeichneClientStatus("SUCHEND", "Keine Serverantwort - erneuter Versuch...")
    end
  end
end
