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

-- AUTO-Regelung:
-- TEMP     = Temperatur regeln
-- ENERGY   = gespeicherte Energie regeln
-- HYBRID   = Temperatur hat Vorrang, Energie ist zweite Regel
local AUTO_SENSOR = "TEMP"
local SCHWELLE_AN, SCHWELLE_AUS = 10, 90
local TEMP_MIN, TEMP_MAX = 750, 1000
local ENERGY_MIN, ENERGY_MAX = 20, 90
local ROD_MIN, ROD_MAX = 0, 100
local ROD_STEP = 5
local gesamtRF_Erzeugt, MODUS, steuerstabZiel = 0, "AUTO", 0
local signalStaerke = 400

if modem.setStrength then modem.setStrength(signalStaerke) end

local lastDaten = {}
local graphHistory = {}
for i = 1, 24 do graphHistory[i] = 0 end

local function clamp(v, lo, hi)
  v = tonumber(v) or lo
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function speichereKonfiguration()
  pcall(function()
    local f = io.open(SAVE_FILE, "w")
    if f then
      f:write(serialization.serialize({
        an = SCHWELLE_AN,
        aus = SCHWELLE_AUS,
        tempMin = TEMP_MIN,
        tempMax = TEMP_MAX,
        energyMin = ENERGY_MIN,
        energyMax = ENERGY_MAX,
        autoSensor = AUTO_SENSOR,
        rods = steuerstabZiel,
        rodMin = ROD_MIN,
        rodMax = ROD_MAX,
        rodStep = ROD_STEP,
        rf = gesamtRF_Erzeugt,
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
    SCHWELLE_AN = clamp(d.an, 0, 100)
    SCHWELLE_AUS = clamp(d.aus, SCHWELLE_AN, 100)
    TEMP_MIN = math.max(1, tonumber(d.tempMin) or 750)
    TEMP_MAX = math.max(TEMP_MIN + 1, tonumber(d.tempMax) or 1000)
    ENERGY_MIN = clamp(d.energyMin, 0, 100)
    ENERGY_MAX = clamp(d.energyMax, ENERGY_MIN, 100)
    local sensor = tostring(d.autoSensor or "TEMP")
    AUTO_SENSOR = (sensor == "ENERGY" or sensor == "HYBRID") and sensor or "TEMP"
    steuerstabZiel = clamp(d.rods, 0, 100)
    ROD_MIN = clamp(d.rodMin, 0, 100)
    ROD_MAX = clamp(d.rodMax, ROD_MIN, 100)
    ROD_STEP = clamp(d.rodStep, 1, 25)
    gesamtRF_Erzeugt = math.max(0, tonumber(d.rf) or 0)
    signalStaerke = clamp(d.strength, 1, 400)
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
    if sg.stargateState then sgState, sgChevrons = sg.stargateState() end
    if sg.irisState then sgIris = sg.irisState() end
    if sg.localAddress then sgAddr = sg.localAddress() end
  end)
  return sgState, tonumber(sgChevrons) or 0, sgIris, sgAddr
end

local function getRodCount(payload)
  return math.max(1, math.floor(tonumber(payload.rodCount) or 1))
end

local function buildRodLevels(target, count)
  local levels = {}
  for i = 0, count - 1 do levels[i] = target end
  return levels
end

local function sendReactorCommand(address, command, rodTarget, payload)
  local target = clamp(rodTarget or steuerstabZiel, ROD_MIN, ROD_MAX)
  local count = getRodCount(payload or {})
  modem.send(address, PORT_REAKTOR, serialization.serialize({
    befehl = command,
    rods = target,
    rodLevels = buildRodLevels(target, count),
    rodStep = ROD_STEP
  }))
end

local function setAutoValue(cmd, value)
  value = tonumber(value)
  if not value then return false end
  if cmd == "SET_TEMP_MIN" then
    TEMP_MIN = math.max(1, math.min(TEMP_MAX - 1, value))
  elseif cmd == "SET_TEMP_MAX" then
    TEMP_MAX = math.max(TEMP_MIN + 1, value)
  elseif cmd == "SET_ENERGY_MIN" then
    ENERGY_MIN = clamp(value, 0, ENERGY_MAX - 1)
  elseif cmd == "SET_ENERGY_MAX" then
    ENERGY_MAX = clamp(value, ENERGY_MIN + 1, 100)
  elseif cmd == "SET_ROD_MIN" then
    ROD_MIN = clamp(value, 0, ROD_MAX)
    steuerstabZiel = math.max(steuerstabZiel, ROD_MIN)
  elseif cmd == "SET_ROD_MAX" then
    ROD_MAX = clamp(value, ROD_MIN, 100)
    steuerstabZiel = math.min(steuerstabZiel, ROD_MAX)
  elseif cmd == "SET_ROD_STEP" then
    ROD_STEP = clamp(value, 1, 25)
  elseif cmd == "SET_AUTO_SENSOR" then
    local s = tostring(value)
    if s ~= "TEMP" and s ~= "ENERGY" and s ~= "HYBRID" then return false end
    AUTO_SENSOR = s
  else
    return false
  end
  speichereKonfiguration()
  return true
end

local function autoControl(payload)
  local temp = tonumber(payload.tempKern) or 0
  local energy = clamp(payload.prozent, 0, 100)
  local active = not not payload.istAktiv
  local target = clamp(steuerstabZiel, ROD_MIN, ROD_MAX)
  local command = "PING"

  if not active then
    if AUTO_SENSOR == "TEMP" then
      if temp <= TEMP_MIN then command = "AN" end
    elseif AUTO_SENSOR == "ENERGY" then
      if energy <= ENERGY_MIN then command = "AN" end
    else
      if temp <= TEMP_MIN and energy <= ENERGY_MIN then command = "AN" end
    end
    return command, target
  end

  -- Harte Sicherheitsgrenze: immer zuerst behandeln.
  if temp >= TEMP_MAX then
    return "AUS", ROD_MAX
  end

  -- Temperaturregelung: heißer = mehr Einstecken, kälter = herausziehen.
  if AUTO_SENSOR == "TEMP" or AUTO_SENSOR == "HYBRID" then
    if temp >= TEMP_MAX - 50 then
      target = math.min(ROD_MAX, target + ROD_STEP)
    elseif temp <= TEMP_MIN then
      target = math.max(ROD_MIN, target - ROD_STEP)
    end
  end

  -- Energiereserve: hohe Energie = mehr Einstecken, niedrige Energie = herausziehen.
  if AUTO_SENSOR == "ENERGY" or AUTO_SENSOR == "HYBRID" then
    if energy >= ENERGY_MAX then
      target = math.min(ROD_MAX, target + ROD_STEP)
    elseif energy <= ENERGY_MIN then
      target = math.max(ROD_MIN, target - ROD_STEP)
    end
  end

  -- Bei sehr hoher Energie im AUTO-Modus zusätzlich abschalten.
  if AUTO_SENSOR == "ENERGY" and energy >= ENERGY_MAX then
    command = "PING"
  end

  return command, target
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
        local proz = clamp(payload.prozent, 0, 100)
        local temp = tonumber(payload.tempKern) or 0

        if payload.istAktiv then
          gesamtRF_Erzeugt = gesamtRF_Erzeugt + ((tonumber(payload.rfProTick) or 0) * 20)
        end
        table.remove(graphHistory, 1)
        table.insert(graphHistory, tonumber(payload.rfProTick) or 0)

        local befehl = "PING"
        if MODUS == "AUTO" then
          befehl, steuerstabZiel = autoControl(payload)
        elseif MODUS == "MANUELL_AN" then
          befehl = "AN"
        elseif MODUS == "MANUELL_AUS" then
          befehl = "AUS"
        end

        steuerstabZiel = clamp(steuerstabZiel, ROD_MIN, ROD_MAX)
        sendReactorCommand(senderAddress, befehl, steuerstabZiel, payload)
        speichereKonfiguration()
      elseif port == PORT_REMOTE and payload.cmd then
        local cmd = tostring(payload.cmd)

        if cmd == "GET_DATA" then
          local syncPaket = {
            lastDaten = lastDaten,
            graphHistory = graphHistory,
            gesamtRF = gesamtRF_Erzeugt,
            an = SCHWELLE_AN,
            aus = SCHWELLE_AUS,
            tempMin = TEMP_MIN,
            tempMax = TEMP_MAX,
            temp = TEMP_MAX,
            energyMin = ENERGY_MIN,
            energyMax = ENERGY_MAX,
            autoSensor = AUTO_SENSOR,
            rods = steuerstabZiel,
            rodMin = ROD_MIN,
            rodMax = ROD_MAX,
            rodStep = ROD_STEP,
            modus = MODUS,
            sgState = sgState,
            sgChevrons = sgChevrons,
            sgIris = sgIris,
            sgAddr = sgAddr
          }
          modem.send(senderAddress, PORT_REMOTE, serialization.serialize(syncPaket))

        elseif cmd == "SET_TEMP_MIN" or cmd == "SET_TEMP_MAX" or
               cmd == "SET_ENERGY_MIN" or cmd == "SET_ENERGY_MAX" or
               cmd == "SET_ROD_MIN" or cmd == "SET_ROD_MAX" or
               cmd == "SET_ROD_STEP" or cmd == "SET_AUTO_SENSOR" then
          setAutoValue(cmd, payload.val)

        elseif cmd == "SET_RODS" then
          steuerstabZiel = clamp(payload.val, ROD_MIN, ROD_MAX)
          speichereKonfiguration()

        elseif cmd == "RODS_DOWN" then
          steuerstabZiel = math.min(ROD_MAX, steuerstabZiel + ROD_STEP)
          speichereKonfiguration()
        elseif cmd == "RODS_UP" then
          steuerstabZiel = math.max(ROD_MIN, steuerstabZiel - ROD_STEP)
          speichereKonfiguration()

        elseif cmd == "SET_MODUS" then
          local neuerModus = tostring(payload.val or "AUTO")
          if neuerModus == "AUTO" or neuerModus == "MANUELL_AN" or neuerModus == "MANUELL_AUS" then
            MODUS = neuerModus
            speichereKonfiguration()
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
