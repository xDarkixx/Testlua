-- Testlua Server Controller
-- OpenComputers 1.7.10 / SGCraft 1.13.3 / BigReactors 0.4.3A
-- Design intentionally kept compatible with the existing SGC film GUI.

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local filesystem = require("filesystem")
local shell = require("shell")

if not component.isAvailable("modem") then
  error("Testlua Server: Modem fehlt")
end

local modem = component.modem
local gpu = component.isAvailable("gpu") and component.gpu or nil
local screen = component.isAvailable("screen") and component.screen or nil
if gpu and screen then pcall(gpu.bind, gpu, screen.address) end

local PORT_REACTOR = 101
local PORT_SERVER = 102
pcall(modem.open, PORT_REACTOR)
pcall(modem.open, PORT_SERVER)

local CONFIG_FILE = "reactor_config.dat"
local AUTO_SENSOR = "TEMP"
local TEMP_MIN, TEMP_MAX = 750, 1000
local ENERGY_MIN, ENERGY_MAX = 20, 90
local ROD_MIN, ROD_MAX, ROD_STEP = 0, 100, 5

local reactor = {
  online=false, active=false, temperature=0, energy=0,
  rods=0, rodLevels={}, lastSeen=0
}
local stargate = {
  proxy=nil, state="Offline", engaged=0, direction="", iris="UNKNOWN", address=""
}
local messageLog = "SYSTEM BEREIT"
local guiDrawn = false

local function setLog(s)
  messageLog = tostring(s or "")
end

local function saveConfig()
  local f = filesystem.open(CONFIG_FILE, "w")
  if not f then return end
  f:write(serialization.serialize({
    sensor=AUTO_SENSOR, tempMin=TEMP_MIN, tempMax=TEMP_MAX,
    energyMin=ENERGY_MIN, energyMax=ENERGY_MAX,
    rodMin=ROD_MIN, rodMax=ROD_MAX, rodStep=ROD_STEP
  }))
  f:close()
end

local function loadConfig()
  if not filesystem.exists(CONFIG_FILE) then return end
  local f = filesystem.open(CONFIG_FILE, "r")
  if not f then return end
  local data = f:read(math.huge)
  f:close()
  local ok,t = pcall(serialization.unserialize, data)
  if ok and type(t)=="table" then
    AUTO_SENSOR=t.sensor or AUTO_SENSOR
    TEMP_MIN=t.tempMin or TEMP_MIN; TEMP_MAX=t.tempMax or TEMP_MAX
    ENERGY_MIN=t.energyMin or ENERGY_MIN; ENERGY_MAX=t.energyMax or ENERGY_MAX
    ROD_MIN=t.rodMin or ROD_MIN; ROD_MAX=t.rodMax or ROD_MAX
    ROD_STEP=t.rodStep or ROD_STEP
  end
end
loadConfig()

-- SGCraft 1.13.3: use the OpenComputers Stargate Interface component.
-- Primary works for the normal one-gate setup; list/proxy is the fallback.
local function findStargate()
  if not component.isAvailable("stargate") then return nil end
  local ok,p = pcall(component.getPrimary, "stargate")
  if ok and p then return p end
  local list = component.list("stargate")
  if list then
    local address = list()
    if address then
      local ok2,proxy = pcall(component.proxy, address)
      if ok2 then return proxy end
    end
  end
  return nil
end

local function callSG(method,...)
  local sg = stargate.proxy
  if not sg or type(sg[method]) ~= "function" then return false,nil end
  local ok,a,b,c = pcall(sg[method], ...)
  if ok then return true,{a,b,c} end
  setLog("SG FEHLER: "..tostring(a))
  return false,nil
end

local function refreshStargate()
  if not stargate.proxy then stargate.proxy=findStargate() end
  if not stargate.proxy then
    stargate.state="Offline"; stargate.iris="N/A"; stargate.address="N/A"
    return
  end
  local ok,r=callSG("stargateState")
  if ok and r then
    stargate.state=tostring(r[1] or "Unknown")
    stargate.engaged=tonumber(r[2] or 0) or 0
    stargate.direction=tostring(r[3] or "")
  end
  local ok2,r2=callSG("irisState")
  if ok2 and r2 then stargate.iris=tostring(r2[1] or r2[1] or "UNKNOWN") end
  local ok3,r3=callSG("localAddress")
  if ok3 and r3 then stargate.address=tostring(r3[1] or "") end
end

local function sendReactor(command,value)
  local packet={cmd=command,value=value}
  modem.broadcast(PORT_REACTOR, serialization.serialize(packet))
end

local function dialGate(address)
  if not address or address=="" then setLog("SG: KEINE ADRESSE"); return end
  if not stargate.proxy then stargate.proxy=findStargate() end
  if not stargate.proxy then setLog("SG: INTERFACE NICHT GEFUNDEN"); return end
  local ok,err=pcall(stargate.proxy.dial, address)
  if ok then setLog("SG: WÄHLE "..address) else setLog("SG DIAL FEHLER: "..tostring(err)) end
end

local function iris(open)
  if not stargate.proxy then stargate.proxy=findStargate() end
  if not stargate.proxy then setLog("SG: INTERFACE NICHT GEFUNDEN"); return end
  local method=open and "openIris" or "closeIris"
  local ok,err=pcall(stargate.proxy[method])
  if ok then setLog(open and "IRIS GEÖFFNET" or "IRIS GESCHLOSSEN")
  else setLog("IRIS FEHLER: "..tostring(err)) end
end

local function disconnectGate()
  if not stargate.proxy then stargate.proxy=findStargate() end
  if not stargate.proxy then setLog("SG: INTERFACE NICHT GEFUNDEN"); return end
  local ok,err=pcall(stargate.proxy.disconnect)
  if ok then setLog("SG: VERBINDUNG GETRENNT") else setLog("SG DISCONNECT FEHLER: "..tostring(err)) end
end

local function drawFrame()
  if not gpu or not screen then return end
  local w,h=gpu.getResolution()
  gpu.fill(1,1,w,h," ")
  gpu.set(2,1,"TESTLUA SERVER // SGC CONTROL")
  gpu.set(2,3,"[ REAKTOR ]   [ STARGATE ]")
  gpu.set(2,5,"REAKTOR TELEMETRIE")
  gpu.set(2,6,"Status: --------")
  gpu.set(2,7,"Temperatur: --------")
  gpu.set(2,8,"Energy:     --------")
  gpu.set(2,9,"Stäbe:      --------")
  gpu.set(2,11,"STARGATE TELEMETRIE")
  gpu.set(2,12,"State:      --------")
  gpu.set(2,13,"Chevron:    --------")
  gpu.set(2,14,"Iris:       --------")
  gpu.set(2,15,"Adresse:    --------")
  gpu.set(2,17,"[ IRIS AUF ] [ IRIS ZU ] [ TRENNEN ]")
  gpu.set(2,19,"[ AUTO ] [ START ] [ STOPP ]")
  gpu.set(2,21,"[ BACKUP ] [ RESTORE ] [ STATUS ]")
  gpu.set(2,23,"LOG:")
  gpu.set(2,24,messageLog:sub(1, math.max(1,w-3)))
  guiDrawn=true
end

local function updateLine(y,text)
  if not gpu or not screen then return end
  local w,h=gpu.getResolution()
  if y>h then return end
  gpu.fill(1,y,w,1," ")
  gpu.set(2,y,text:sub(1,math.max(1,w-3)))
end

local function refreshGUI()
  if not gpu or not screen then return end
  if not guiDrawn then drawFrame() end
  updateLine(6,"Status:      "..(reactor.online and (reactor.active and "AKTIV" or "AUS") or "OFFLINE"))
  updateLine(7,string.format("Temperatur:  %.1f C",reactor.temperature or 0))
  updateLine(8,string.format("Energy:      %.1f %%",reactor.energy or 0))
  updateLine(9,string.format("Stäbe:       %d",reactor.rods or 0))
  updateLine(12,"State:       "..stargate.state)
  updateLine(13,"Chevron:     "..tostring(stargate.engaged))
  updateLine(14,"Iris:        "..stargate.iris)
  updateLine(15,"Adresse:     "..stargate.address)
  updateLine(24,"LOG: "..messageLog)
end

local function handleTouch(x,y)
  if y==17 then
    if x<18 then iris(true) elseif x<34 then iris(false) elseif x<55 then disconnectGate() end
  elseif y==19 then
    if x<14 then sendReactor("AUTO",true); setLog("REAKTOR: AUTO")
    elseif x<29 then sendReactor("AN",true); setLog("REAKTOR: START")
    elseif x<48 then sendReactor("AUS",true); setLog("REAKTOR: STOPP") end
  elseif y==21 then
    if x<15 then shell.execute("floppy_backup.lua", "backup")
    elseif x<30 then shell.execute("floppy_backup.lua", "restore")
    else shell.execute("floppy_backup.lua", "status") end
  end
  refreshGUI()
end

local function handlePacket(a,b,c,d,e)
  -- OpenComputers modem_message:
  -- event, localAddress, remoteAddress, port, distance, message
  local senderAddress=b
  local port=tonumber(c)
  local message=e
  if port~=PORT_REACTOR and port~=PORT_SERVER then return end
  if type(message)=="string" then
    local ok,p=pcall(serialization.unserialize,message)
    if ok and type(p)=="table" then message=p end
  end
  if type(message)~="table" then return end

  if port==PORT_REACTOR then
    reactor.online=true; reactor.lastSeen=os.clock()
    reactor.active=message.active==true or message.active==1
    reactor.temperature=tonumber(message.temperature or message.temp or 0) or 0
    reactor.energy=tonumber(message.energy or message.energyPercent or 0) or 0
    reactor.rods=tonumber(message.rods or message.rodLevel or 0) or 0
    if type(message.rodLevels)=="table" then reactor.rodLevels=message.rodLevels end
  elseif port==PORT_SERVER then
    local cmd=message.cmd
    if cmd=="SG_DIAL" then dialGate(message.address)
    elseif cmd=="SG_IRIS_OPEN" then iris(true)
    elseif cmd=="SG_IRIS_CLOSE" then iris(false)
    elseif cmd=="SG_DISCONNECT" then disconnectGate()
    end
  end
end

if gpu and screen then drawFrame() end
refreshStargate(); refreshGUI()

local lastSG=0
while true do
  local ev,a,b,c,d,e=event.pullMultiple(0.5,"modem_message","touch")
  if ev=="modem_message" then
    handlePacket(a,b,c,d,e)
  elseif ev=="touch" then
    -- touch: event, screenAddress, x, y, button, user
    handleTouch(tonumber(b) or 0, tonumber(c) or 0)
  end
  if os.clock()-lastSG>1 then
    lastSG=os.clock()
    refreshStargate()
    if reactor.online and os.clock()-reactor.lastSeen>4 then reactor.online=false end
    refreshGUI()
  end
end
