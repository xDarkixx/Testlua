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

local reactor = component.br_reactor
local modem = component.modem
local gpu = component.gpu
local rs = component.redstone
local PORT = 101
modem.open(PORT)

-- 14 Zeilen Höhe verhindert Flackern und automatisches Scrollen
gpu.setResolution(50, 14)
gpu.setBackground(0x0C0F12)
term.clear()

local FARBE_WEISS = 0  
local FARBE_ROT = 14   

local function setzeSignalAufAllenSeiten(farbe, staerke)
  for seite = 0, 5 do rs.setBundledOutput(seite, farbe, staerke) end
end

local function zeichneClientStatus(verbindungsStatus, detailText)
  term.clear()
  gpu.setForeground(0x56B3FA)
  print("==================================================")
  print("        REAKTOR-NETZWERK CLIENT v9.1             ")
  print("==================================================")
  io.write(" Status: ")
  if verbindungsStatus == "ONLINE" then
    gpu.setForeground(0x2ECC71) print("[ VERBUNDEN ]")
    setzeSignalAufAllenSeiten(FARBE_WEISS, 15) setzeSignalAufAllenSeiten(FARBE_ROT, 0)
  elseif verbindungsStatus == "SUCHEND" then
    gpu.setForeground(0xF1C40F) print("[ WARTE AUF SERVER... ]")
    setzeSignalAufAllenSeiten(FARBE_WEISS, 0) setzeSignalAufAllenSeiten(FARBE_ROT, 15)
  else
    gpu.setForeground(0xE74C3C) print("[ OFFLINE / DISCONNECT ]")
    setzeSignalAufAllenSeiten(FARBE_WEISS, 0) setzeSignalAufAllenSeiten(FARBE_ROT, 15)
  end
  gpu.setForeground(0xECF0F1)
  print(" Info: " .. (detailText or "Initialisiere..."))
  print("==================================================")
end

zeichneClientStatus("SUCHEND", "Sende erste Datenpakete ins Netzwerk...")

while true do
  local energieAktuell = tonumber(reactor.getEnergyStored()) or 0
  local energieMax = 10000000 
  local prozent = (energieAktuell / energieMax) * 100
  local aktuelleStaebe = math.floor(tonumber(reactor.getControlRodInsertion(0)) or 0)
  
  local fuelAmt = math.floor(tonumber(reactor.getFuelAmount()) or 0)
  local wasteAmt = math.floor(tonumber(reactor.getWasteAmount()) or 0)
  local maxFuel = tonumber(reactor.getFuelAmountMax and reactor.getFuelAmountMax() or 1000) or 1000
  local fuelPct = (maxFuel > 0) and ((fuelAmt / maxFuel) * 100) or 0
  local wastePct = (maxFuel > 0) and ((wasteAmt / maxFuel) * 100) or 0
  
  local daten = {
    prozent = prozent,
    tempKern = math.floor(tonumber(reactor.getFuelTemperature()) or 0),
    rfProTick = math.floor(tonumber(reactor.getEnergyProducedLastTick()) or 0),
    istAktiv = not not reactor.getActive(),
    steuerstaebe = aktuelleStaebe,
    fuelAmt = fuelAmt,
    wasteAmt = wasteAmt,
    fuelPct = fuelPct,
    wastePct = wastePct,
    hatTurbine = false,
    turbineRPM = 0,
    turbineDampf = 0
  }
  
  if component.isAvailable("br_turbine") then
    local turbine = component.br_turbine
    daten.hatTurbine = true
    daten.turbineRPM = math.floor(tonumber(turbine.getRotorSpeed()) or 0)
    local getCap = turbine.getFluidAmountMax or turbine.getFluidCapacity
    if getCap then
      daten.turbineDampf = math.floor(tonumber(getCap()) or 0)
    end
    daten.rfProTick = math.floor(tonumber(turbine.getEnergyProducedLastTick()) or 0)
  end
  
  modem.broadcast(PORT, serialization.serialize(daten))
  
  local eventTyp, _, _, _, _, netzwerkAntwort = event.pull(4.0, "modem_message")
  if eventTyp == "modem_message" and netzwerkAntwort and tostring(netzwerkAntwort) ~= "" then
    local success, serverBefehl = pcall(serialization.unserialize, tostring(netzwerkAntwort))
    if success and serverBefehl and type(serverBefehl) == "table" then
      if serverBefehl.befehl == "AN" then reactor.setActive(true)
      elseif serverBefehl.befehl == "AUS" then reactor.setActive(false) end
      if serverBefehl.rods then reactor.setAllControlRodInsertion(tonumber(serverBefehl.rods) or 0) end
      zeichneClientStatus("ONLINE", string.format("Server aktiv | Leistung: %d RF/t", daten.rfProTick))
      if not reactor.getActive() then setzeSignalAufAllenSeiten(FARBE_WEISS, 0) end
    end
  else
    if reactor.getActive() then reactor.setActive(false) end
    zeichneClientStatus("OFFLINE", "Watchdog-Timeout! Notabschaltung aktiv.")
    for i = 1, 3 do
      setzeSignalAufAllenSeiten(FARBE_ROT, 15) os.sleep(0.25)
      setzeSignalAufAllenSeiten(FARBE_ROT, 0) os.sleep(0.25)
    end
  end
  os.sleep(1.5)
end
