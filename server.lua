local component = require("component")
local event = require("event")
local serialization = require("serialization")
local fs = require("filesystem")
local shell = require("shell")

if not component.isAvailable("modem") then
  io.stderr:write("Fehler: Netzwerkkarte (Modem) fehlt am Server!\n")
  return
end

local modem = component.modem
local PORT_REAKTOR = 101
local PORT_REMOTE = 102
modem.open(PORT_REAKTOR)
modem.open(PORT_REMOTE)

local currentDir = shell.getWorkingDirectory() or "/"
local SAVE_FILE = fs.concat(currentDir, "reactor_config.dat")

local SCHWELLE_AN, SCHWELLE_AUS, TEMP_LIMIT, gesamtRF_Erzeugt, MODUS, steuerstabZiel = 10, 90, 1000, 0, "AUTO", 0
local signalStaerke = 400
if modem.setStrength then modem.setStrength(signalStaerke) end

local lastDaten = {}
local graphHistory = {}
for i = 1, 24 do graphHistory[i] = 0 end

-- Sicheres Laden mit Prüfung auf 'EOF' und korrupte Dateien
if fs.exists(SAVE_FILE) then
  local file = io.open(SAVE_FILE, "r")
  if file then
    local inhalt = file:read("*all") or ""
    file:close()
    if inhalt ~= "" and #inhalt > 2 then
      local success, d = pcall(serialization.unserialize, inhalt)
      if success and d and type(d) == "table" then
        SCHWELLE_AN = tonumber(d.an) or 10
        SCHWELLE_AUS = tonumber(d.aus) or 90
        TEMP_LIMIT = tonumber(d.temp) or 1000
        gesamtRF_Erzeugt = tonumber(d.rf) or 0
        steuerstabZiel = tonumber(d.rods) or 0
        signalStaerke = tonumber(d.strength) or 400
        if modem.setStrength then modem.setStrength(signalStaerke) end
      end
    end
  end
end

local function speichereKonfiguration()
  pcall(function()
    local f = io.open(SAVE_FILE, "w")
    if f then 
      f:write(serialization.serialize({
        an = SCHWELLE_AN, 
        aus = SCHWELLE_AUS, 
        temp = TEMP_LIMIT, 
        rf = gesamtRF_Erzeugt, 
        rods = steuerstabZiel, 
        strength = signalStaerke
      })) 
      f:close() 
    end
  end)
end

while true do
  local eventTyp, _, senderAddress, port, _, message = event.pullMultiple(1.0, "modem_message")
  
  local sgState, sgChevrons, sgIris, sgAddr = "No Gate", 0, "Open", "N/A"
  if component.isAvailable("stargate") then
    pcall(function()
      local sg = component.stargate
      if sg.stargateState then
        sgState, sgChevrons = sg.stargateState()
      end
      sgIris = sg.irisState and sg.irisState() or "Open"
      sgAddr = sg.localAddress and sg.localAddress() or "N/A"
    end)
  end

  if eventTyp == "modem_message" and message and tostring(message) ~= "" then
    local success, payload = pcall(serialization.unserialize, tostring(message))
    
    if success and payload and type(payload) == "table" then
      if port == PORT_REAKTOR and payload.prozent then
        lastDaten = payload
        if payload.istAktiv then 
          gesamtRF_Erzeugt = gesamtRF_Erzeugt + ((tonumber(payload.rfProTick) or 0) * 20)
        end
        table.remove(graphHistory, 1) 
        table.insert(graphHistory, tonumber(payload.rfProTick) or 0)
        
        local befehl = "PING"
        local proz = tonumber(payload.prozent) or 0
        if MODUS == "AUTO" then
          if payload.istAktiv and proz >= SCHWELLE_AUS then befehl = "AUS"
          elseif not payload.istAktiv and proz <= SCHWELLE_AN then befehl = "AN" end
        elseif MODUS == "MANUELL_AN" and not payload.istAktiv then befehl = "AN"
        elseif MODUS == "MANUELL_AUS" and payload.istAktiv then befehl = "AUS" end
        
        modem.send(senderAddress, PORT_REAKTOR, serialization.serialize({befehl=befehl, rods=steuerstabZiel}))
        
      elseif port == PORT_REMOTE and payload.cmd then
        local cmd = payload.cmd
        if cmd == "GET_DATA" then
          local syncPaket = {
            lastDaten = lastDaten, 
            graphHistory = graphHistory, 
            gesamtRF = gesamtRF_Erzeugt,
            an = SCHWELLE_AN, 
            aus = SCHWELLE_AUS, 
            temp = TEMP_LIMIT, 
            rods = steuerstabZiel, 
            modus = MODUS,
            sgState = sgState, 
            sgChevrons = sgChevrons, 
            sgIris = sgIris, 
            sgAddr = sgAddr
          }
          modem.send(senderAddress, PORT_REMOTE, serialization.serialize(syncPaket))
          
        elseif cmd == "RODS_DOWN" and steuerstabZiel <= 90 then 
          steuerstabZiel = steuerstabZiel + 10 
          speichereKonfiguration()
        elseif cmd == "RODS_UP" and steuerstabZiel >= 10 then 
          steuerstabZiel = steuerstabZiel - 10 
          speichereKonfiguration()
        elseif cmd == "SET_MODUS" then 
          MODUS = payload.val or "AUTO"
        elseif cmd == "SG_IRIS_OPEN" and component.isAvailable("stargate") then 
          pcall(function() component.stargate.openIris() end)
        elseif cmd == "SG_IRIS_CLOSE" and component.isAvailable("stargate") then 
          pcall(function() component.stargate.closeIris() end)
        elseif cmd == "SG_DISCONNECT" and component.isAvailable("stargate") then 
          pcall(function() component.stargate.disconnect() end)
        elseif cmd == "SG_DIAL" and component.isAvailable("stargate") then 
          pcall(function() component.stargate.dial(payload.val) end)
        end
      end
    end
  end
end
