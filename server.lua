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

local SCHWELLE_AN, SCHWELLE_AUS, TEMP_LIMIT = 10, 90, 1000
local gesamtRF_Erzeugt, MODUS, steuerstabZiel = 0, "AUTO", 0
local signalStaerke = 400
if modem.setStrength then modem.setStrength(signalStaerke) end

local lastDaten = {}
local graphHistory = {}
for i = 1, 24 do graphHistory[i] = 0 end

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

local function ladeKonfiguration()
  if not fs.exists(SAVE_FILE) then return end
  local f = io.open(SAVE_FILE, "r")
  if not f then return end
  local inhalt = f:read("*all") or ""
  f:close()
  if #inhalt < 3 then return end

  local ok, d = pcall(serialization.unserialize, inhalt)
  if ok and type(d) == "table" then
    SCHWELLE_AN = math.max(0, math.min(100, tonumber(d.an) or 10))
    SCHWELLE_AUS = math.max(SCHWELLE_AN, math.min(100, tonumber(d.aus) or 90))
    TEMP_LIMIT = math.max(1, tonumber(d.temp) or 1000)
    gesamtRF_Erzeugt = math.max(0, tonumber(d.rf) or 0)
    steuerstabZiel = math.max(0, math.min(100, tonumber(d.rods) or 0))
    signalStaerke = math.max(1, math.min(400, tonumber(d.strength) or 400))
    if modem.setStrength then modem.setStrength(signalStaerke) end
  end
end

local function getStargate()
  if not component.isAvailable("stargate") then return nil end
  local ok, sg = pcall(component.getPrimary, "stargate")
  if ok and sg then return sg end
  return component.stargate
end

local function getStargateData()
  local sgState, sgChevrons, sgIris, sgAddr = "No Gate", 0, "Open", "N/A"
  local sg = getStargate()
  if not sg then return sgState, sgChevrons, sgIris, sgAddr end

  pcall(function()
    if sg.stargateState then
      sgState, sgChevrons = sg.stargateState()
    end
    if sg.irisState then sgIris = sg.irisState() end
    if sg.localAddress then sgAddr = sg.localAddress() end
  end)
  return sgState, tonumber(sgChevrons) or 0, sgIris, sgAddr
end

local function sendReactorCommand(address, command)
  modem.send(address, PORT_REAKTOR, serialization.serialize({
    befehl = command,
    rods = steuerstabZiel
  }))
end

ladeKonfiguration()

while true do
  local eventTyp, _, senderAddress, port, _, message = event.pullMultiple(1.0, "modem_message")

  local sgState, sgChevrons, sgIris, sgAddr = getStargateData()

  if eventTyp == "modem_message" and message and tostring(message) ~= "" then
    local success, payload = pcall(serialization.unserialize, tostring(message))

    if success and type(payload) == "table" then
      if port == PORT_REAKTOR and payload.prozent ~= nil then
        lastDaten = payload
        local proz = math.max(0, math.min(100, tonumber(payload.prozent) or 0))
        local temp = tonumber(payload.tempKern) or 0

        if payload.istAktiv then
          gesamtRF_Erzeugt = gesamtRF_Erzeugt + ((tonumber(payload.rfProTick) or 0) * 20)
        end
        table.remove(graphHistory, 1)
        table.insert(graphHistory, tonumber(payload.rfProTick) or 0)

        -- Harte Temperaturabschaltung: Temperaturgrenze hat Vorrang vor AUTO/MANUELL.
        if payload.istAktiv and temp >= TEMP_LIMIT then
          sendReactorCommand(senderAddress, "AUS")
          steuerstabZiel = 100
          speichereKonfiguration()
        else
          local befehl = "PING"
          if MODUS == "AUTO" then
            if payload.istAktiv and proz >= SCHWELLE_AUS then
              befehl = "AUS"
            elseif not payload.istAktiv and proz <= SCHWELLE_AN then
              befehl = "AN"
            end
          elseif MODUS == "MANUELL_AN" and not payload.istAktiv then
            befehl = "AN"
          elseif MODUS == "MANUELL_AUS" and payload.istAktiv then
            befehl = "AUS"
          end
          sendReactorCommand(senderAddress, befehl)
        end

      elseif port == PORT_REMOTE and payload.cmd then
        local cmd = tostring(payload.cmd)

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

        elseif cmd == "RODS_DOWN" then
          steuerstabZiel = math.min(100, steuerstabZiel + 10)
          speichereKonfiguration()

        elseif cmd == "RODS_UP" then
          steuerstabZiel = math.max(0, steuerstabZiel - 10)
          speichereKonfiguration()

        elseif cmd == "SET_MODUS" then
          local neuerModus = tostring(payload.val or "AUTO")
          if neuerModus == "AUTO" or neuerModus == "MANUELL_AN" or neuerModus == "MANUELL_AUS" then
            MODUS = neuerModus
          end

        else
          local sg = getStargate()
          if sg then
            if cmd == "SG_IRIS_OPEN" and sg.openIris then
              pcall(sg.openIris)
            elseif cmd == "SG_IRIS_CLOSE" and sg.closeIris then
              pcall(sg.closeIris)
            elseif cmd == "SG_DISCONNECT" and sg.disconnect then
              pcall(sg.disconnect)
            elseif cmd == "SG_DIAL" and sg.dial and type(payload.val) == "string" then
              pcall(sg.dial, payload.val)
            end
          end
        end
      end
    end
  end
end
