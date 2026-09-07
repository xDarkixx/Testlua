-- Testlua Server Controller
-- OpenComputers 1.7.10 / SGCraft 1.13.3 / BigReactors 0.4.3A
-- Existing SGC film-style remote design is intentionally preserved.

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local filesystem = require("filesystem")
local shell = require("shell")
local computer = require("computer")

if not component.isAvailable("modem") then error("Testlua Server: Modem fehlt") end
local modem = component.modem
local gpu = component.isAvailable("gpu") and component.gpu or nil
local screen = component.isAvailable("screen") and component.screen or nil
if gpu and screen then pcall(gpu.bind, gpu, screen.address) end

local PORT_REACTOR, PORT_SERVER = 101, 102
pcall(modem.open, PORT_REACTOR)
pcall(modem.open, PORT_SERVER)
if modem.setStrength then pcall(modem.setStrength, 400) end

local CONFIG_FILE="reactor_config.dat"
-- Jede Schutzfunktion ist separat schaltbar.
local TEMP_SHUTDOWN_ENABLED=true
local ENERGY_SHUTDOWN_ENABLED=true
local AUTO_START_TEMP_ENABLED=true
local AUTO_START_ENERGY_ENABLED=true
local TEMP_MIN,TEMP_MAX=750,1000
local ENERGY_MIN,ENERGY_MAX=20,90
local ROD_MIN,ROD_MAX,ROD_STEP=0,100,5
local modus="AUTO"

local reactor={online=false,active=false,temperature=0,casingTemp=0,energy=0,energyStored=0,energyMax=0,rods=0,rodLevels={},lastSeen=0,rfProTick=0,fuelAmt=0,wasteAmt=0,rodCount=0}
local sg={proxy=nil,state="Offline",engaged=0,direction="",iris="UNKNOWN",address="N/A"}
local messageLog="SYSTEM BEREIT"
local guiDrawn=false

local function setLog(s) messageLog=tostring(s or "") end
local function saveConfig()
 local f=filesystem.open(CONFIG_FILE,"w"); if not f then return end
 f:write(serialization.serialize({
  tempShutdown=TEMP_SHUTDOWN_ENABLED,energyShutdown=ENERGY_SHUTDOWN_ENABLED,
  autoStartTemp=AUTO_START_TEMP_ENABLED,autoStartEnergy=AUTO_START_ENERGY_ENABLED,
  tempMin=TEMP_MIN,tempMax=TEMP_MAX,energyMin=ENERGY_MIN,energyMax=ENERGY_MAX,
  rodMin=ROD_MIN,rodMax=ROD_MAX,rodStep=ROD_STEP
 })); f:close()
end
local function loadConfig()
 if not filesystem.exists(CONFIG_FILE) then return end
 local f=filesystem.open(CONFIG_FILE,"r"); if not f then return end
 local d=f:read(math.huge); f:close(); local ok,t=pcall(serialization.unserialize,d)
 if ok and type(t)=="table" then
  if t.tempShutdown~=nil then TEMP_SHUTDOWN_ENABLED=t.tempShutdown==true end
  if t.energyShutdown~=nil then ENERGY_SHUTDOWN_ENABLED=t.energyShutdown==true end
  if t.autoStartTemp~=nil then AUTO_START_TEMP_ENABLED=t.autoStartTemp==true end
  if t.autoStartEnergy~=nil then AUTO_START_ENERGY_ENABLED=t.autoStartEnergy==true end
  TEMP_MIN=tonumber(t.tempMin) or TEMP_MIN; TEMP_MAX=tonumber(t.tempMax) or TEMP_MAX
  ENERGY_MIN=tonumber(t.energyMin) or ENERGY_MIN; ENERGY_MAX=tonumber(t.energyMax) or ENERGY_MAX
  ROD_MIN=tonumber(t.rodMin) or ROD_MIN; ROD_MAX=tonumber(t.rodMax) or ROD_MAX; ROD_STEP=tonumber(t.rodStep) or ROD_STEP
 end
end
loadConfig()

local function findStargate()
 if not component.isAvailable("stargate") then return nil end
 local ok,p=pcall(component.getPrimary,"stargate"); if ok and p then return p end
 local list=component.list("stargate")
 if list then local addr=list(); if addr then local ok2,p2=pcall(component.proxy,addr); if ok2 then return p2 end end end
 return nil
end
local function ensureSG() if not sg.proxy then sg.proxy=findStargate() end return sg.proxy end
local function sgcall(method,...)
 local p=ensureSG(); if not p or type(p[method])~="function" then return false,nil end
 local ok,a,b,c=pcall(p[method],...); if not ok then setLog("SG FEHLER: "..tostring(a)); return false,nil end
 return true,{a,b,c}
end
local function refreshSG()
 if not ensureSG() then sg.state="Offline"; sg.engaged=0; sg.iris="N/A"; sg.address="N/A"; return end
 local ok,r=sgcall("stargateState"); if ok and r then sg.state=tostring(r[1] or "Unknown"); sg.engaged=tonumber(r[2] or 0) or 0; sg.direction=tostring(r[3] or "") end
 local ok2,r2=sgcall("irisState"); if ok2 and r2 then sg.iris=tostring(r2[1] or "UNKNOWN") end
 local ok3,r3=sgcall("localAddress"); if ok3 and r3 then sg.address=tostring(r3[1] or "N/A") end
end
local function sgAction(method,arg)
 local p=ensureSG(); if not p or type(p[method])~="function" then setLog("SG: "..method.." NICHT VERFÜGBAR"); return false end
 local ok,err
 if arg~=nil then ok,err=pcall(p[method],arg) else ok,err=pcall(p[method]) end
 if not ok then setLog("SG FEHLER: "..tostring(err)); return false end
 return true
end
local function dialGate(addr) addr=tostring(addr or ""); if addr=="" then setLog("SG: KEINE ADRESSE"); return end; if sgAction("dial",addr) then setLog("SG: WÄHLE "..addr) end end
local function iris(open) if sgAction(open and "openIris" or "closeIris") then setLog(open and "IRIS GEÖFFNET" or "IRIS GESCHLOSSEN") end end
local function disconnectGate() if sgAction("disconnect") then setLog("SG: VERBINDUNG GETRENNT") end end

local function sendReactor(cmd,val)
 local payload={befehl=cmd}
 if cmd=="RODS" then payload.rods=val end
 if val~=nil then payload.value=val end
 pcall(modem.broadcast,PORT_REACTOR,serialization.serialize(payload))
end

local function averageRods()
 if type(reactor.rodLevels)=="table" and reactor.rodCount>0 then
  local sum,count=0,0
  for i=0,reactor.rodCount-1 do local v=tonumber(reactor.rodLevels[i]); if v then sum=sum+v; count=count+1 end end
  if count>0 then return sum/count end
 end
 return tonumber(reactor.rods) or 0
end
local function makeRodLevels(level)
 level=math.max(ROD_MIN,math.min(ROD_MAX,tonumber(level) or 0)); local levels={}; local count=math.max(1,tonumber(reactor.rodCount) or 1)
 for i=0,count-1 do levels[i]=level end
 return levels
end
local function setRods(level)
 level=math.max(ROD_MIN,math.min(ROD_MAX,tonumber(level) or 0)); reactor.rods=level; reactor.rodLevels=makeRodLevels(level); sendReactor("RODS",level)
end
local function changeRods(delta) setRods(averageRods()+delta); setLog(string.format("STÄBE: %.0f %%",reactor.rods)) end

local function autoControl()
 if modus~="AUTO" or not reactor.online then return end

 -- Temperaturabschaltung und Energieabschaltung arbeiten unabhängig voneinander.
 if TEMP_SHUTDOWN_ENABLED and reactor.temperature>=TEMP_MAX then
  setRods(ROD_MAX); sendReactor("AUS",true); setLog("AUTO: TEMPERATUR-LIMIT - AUS"); return
 end
 if ENERGY_SHUTDOWN_ENABLED and reactor.energy>=ENERGY_MAX then
  setRods(ROD_MAX); sendReactor("AUS",true); setLog("AUTO: ENERGIE-LIMIT - AUS"); return
 end

 -- Automatischer Start ist ebenfalls separat schaltbar.
 local tempOK=(not TEMP_SHUTDOWN_ENABLED) or reactor.temperature<=TEMP_MIN
 local energyOK=(not ENERGY_SHUTDOWN_ENABLED) or reactor.energy<=ENERGY_MIN
 local startAllowed=true
 if AUTO_START_TEMP_ENABLED and TEMP_SHUTDOWN_ENABLED and not tempOK then startAllowed=false end
 if AUTO_START_ENERGY_ENABLED and ENERGY_SHUTDOWN_ENABLED and not energyOK then startAllowed=false end
 if startAllowed and (AUTO_START_TEMP_ENABLED or AUTO_START_ENERGY_ENABLED) then
  local trigger=(AUTO_START_TEMP_ENABLED and TEMP_SHUTDOWN_ENABLED and reactor.temperature<=TEMP_MIN) or
                (AUTO_START_ENERGY_ENABLED and ENERGY_SHUTDOWN_ENABLED and reactor.energy<=ENERGY_MIN)
  if trigger then setRods(ROD_MIN); sendReactor("AN",true); setLog("AUTO: START-LIMIT ERREICHT") end
 end
end

local function makeStatus()
 return {
  modus=modus,temp=reactor.temperature,casingTemp=reactor.casingTemp,rods=reactor.rods,
  gesamtRF=reactor.rfProTick,energyStored=reactor.energyStored,energyMax=reactor.energyMax,
  lastDaten={tempKern=reactor.temperature,casingTemp=reactor.casingTemp,rfProTick=reactor.rfProTick,
   prozent=reactor.energy,energyStored=reactor.energyStored,energyMax=reactor.energyMax,
   steuerstaebe=reactor.rods,fuelAmt=reactor.fuelAmt,wasteAmt=reactor.wasteAmt,rodLevels=reactor.rodLevels,rodCount=reactor.rodCount},
  reactorOnline=reactor.online,reactorActive=reactor.active,sgState=sg.state,sgChevrons=sg.engaged,
  sgIris=sg.iris,sgAddress=sg.address,sgDirection=sg.direction,log=messageLog,
  tempShutdownEnabled=TEMP_SHUTDOWN_ENABLED,energyShutdownEnabled=ENERGY_SHUTDOWN_ENABLED,
  autoStartTempEnabled=AUTO_START_TEMP_ENABLED,autoStartEnergyEnabled=AUTO_START_ENERGY_ENABLED,
  tempMin=TEMP_MIN,tempMax=TEMP_MAX,energyMin=ENERGY_MIN,energyMax=ENERGY_MAX
 }
end
local function sendStatus(to) if to then pcall(modem.send,to,PORT_SERVER,serialization.serialize(makeStatus())) end end

local function drawFrame()
 if not gpu or not screen then return end
 local w,h=gpu.getResolution(); gpu.fill(1,1,w,h," ")
 gpu.set(2,1,"TESTLUA SERVER // SGC CONTROL"); gpu.set(2,3,"[ REAKTOR ]   [ STARGATE ]")
 gpu.set(2,5,"REAKTOR TELEMETRIE"); gpu.set(2,6,"Status:      --------"); gpu.set(2,7,"Temperatur:  --------"); gpu.set(2,8,"Energy:      --------"); gpu.set(2,9,"Stäbe:       --------")
 gpu.set(2,11,"STARGATE TELEMETRIE"); gpu.set(2,12,"State:       --------"); gpu.set(2,13,"Chevron:     --------"); gpu.set(2,14,"Iris:        --------"); gpu.set(2,15,"Adresse:     --------")
 gpu.set(2,17,"[ IRIS AUF ] [ IRIS ZU ] [ TRENNEN ]"); gpu.set(2,19,"[ AUTO ] [ START ] [ STOPP ]"); gpu.set(2,21,"[ BACKUP ] [ RESTORE ] [ STATUS ]"); gpu.set(2,23,"LOG:"); gpu.set(2,24,messageLog); guiDrawn=true
end
local function line(y,t) if not gpu or not screen then return end; local w,h=gpu.getResolution(); if y>h then return end; gpu.fill(1,y,w,1," "); gpu.set(2,y,tostring(t):sub(1,math.max(1,w-3))) end
local function refreshGUI()
 if not gpu or not screen then return end
 if not guiDrawn then drawFrame() end
 line(6,"Status:      "..(reactor.online and (reactor.active and "AKTIV" or "AUS") or "OFFLINE")); line(7,string.format("Temperatur:  %.1f C",reactor.temperature or 0)); line(8,string.format("Energy:      %.1f %%",reactor.energy or 0)); line(9,string.format("Stäbe:       %.0f %%",reactor.rods or 0))
 line(12,"State:       "..sg.state); line(13,"Chevron:     "..tostring(sg.engaged)); line(14,"Iris:        "..sg.iris); line(15,"Adresse:     "..sg.address); line(24,"LOG: "..messageLog)
end
local function touch(x,y)
 if y==17 then if x<18 then iris(true) elseif x<34 then iris(false) elseif x<55 then disconnectGate() end
 elseif y==19 then if x<14 then modus="AUTO"; setLog("REAKTOR: AUTO") elseif x<29 then modus="MANUELL_AN"; sendReactor("AN",true); setLog("REAKTOR: START") elseif x<48 then modus="MANUELL_AUS"; sendReactor("AUS",true); setLog("REAKTOR: STOPP") end
 elseif y==21 then if x<15 then shell.execute("floppy_backup.lua","backup") elseif x<30 then shell.execute("floppy_backup.lua","restore") else shell.execute("floppy_backup.lua","status") end end
 refreshGUI()
end

local function packet(localAddress,senderAddress,port,distance,message)
 port=tonumber(port); if port~=PORT_REACTOR and port~=PORT_SERVER then return end
 if type(message)=="string" then local ok,p=pcall(serialization.unserialize,message); if ok and type(p)=="table" then message=p end end
 if type(message)~="table" then return end
 if port==PORT_REACTOR then
  reactor.online=true; reactor.lastSeen=computer.uptime(); reactor.active=message.active==true or message.active==1 or message.istAktiv==true
  reactor.temperature=tonumber(message.temperature or message.temp or message.tempKern or 0) or 0
  reactor.casingTemp=tonumber(message.casingTemp or message.tempCasing or message.gehaeuseTemp or 0) or 0
  reactor.energy=tonumber(message.energy or message.energyPercent or message.prozent or 0) or 0
  reactor.energyStored=tonumber(message.energyStored or message.rfStored or message.energyAmount or 0) or 0
  reactor.energyMax=tonumber(message.energyMax or message.rfCapacity or message.maxEnergy or 0) or 0
  reactor.rods=tonumber(message.rods or message.rodLevel or message.steuerstaebe or 0) or 0
  reactor.rfProTick=tonumber(message.rfProTick or message.rf or message.rft or 0) or 0
  reactor.fuelAmt=tonumber(message.fuelAmt or message.fuel or 0) or 0
  reactor.wasteAmt=tonumber(message.wasteAmt or message.waste or 0) or 0
  reactor.rodCount=tonumber(message.rodCount or reactor.rodCount or 0) or 0
  if type(message.rodLevels)=="table" then reactor.rodLevels=message.rodLevels end
  autoControl()
  -- ACK für den Reactor ebenfalls auf Port 101; Status für Remotes bleibt auf 102.
  local ack={ack="REACTOR",online=true,active=reactor.active,rfProTick=reactor.rfProTick,temp=reactor.temperature,energy=reactor.energy}
  pcall(modem.send,senderAddress,PORT_REACTOR,serialization.serialize(ack))
  sendStatus(senderAddress)
 elseif port==PORT_SERVER then
  if message.cmd=="GET_DATA" then sendStatus(senderAddress)
  elseif message.cmd=="SG_DIAL" then dialGate(message.address or message.val); sendStatus(senderAddress)
  elseif message.cmd=="SG_IRIS_OPEN" then iris(true); sendStatus(senderAddress)
  elseif message.cmd=="SG_IRIS_CLOSE" then iris(false); sendStatus(senderAddress)
  elseif message.cmd=="SG_DISCONNECT" then disconnectGate(); sendStatus(senderAddress)
  elseif message.cmd=="RODS_UP" then changeRods(-ROD_STEP); sendStatus(senderAddress)
  elseif message.cmd=="RODS_DOWN" then changeRods(ROD_STEP); sendStatus(senderAddress)
  elseif message.cmd=="SET_MODUS" then
   local requested=tostring(message.val or "AUTO"); if requested=="AUTO" or requested=="MANUELL_AN" or requested=="MANUELL_AUS" then modus=requested end
   if modus=="MANUELL_AN" then sendReactor("AN",true) elseif modus=="MANUELL_AUS" then sendReactor("AUS",true) end
   setLog("MODUS: "..modus); sendStatus(senderAddress)
  elseif message.cmd=="AUTO" then modus="AUTO"; setLog("REAKTOR: AUTO"); sendStatus(senderAddress)
  elseif message.cmd=="AN" then modus="MANUELL_AN"; sendReactor("AN",true); setLog("REAKTOR: START"); sendStatus(senderAddress)
  elseif message.cmd=="AUS" then modus="MANUELL_AUS"; sendReactor("AUS",true); setLog("REAKTOR: STOPP"); sendStatus(senderAddress)
  elseif message.cmd=="SET_SAFETY" then
   if message.tempEnabled~=nil then TEMP_SHUTDOWN_ENABLED=message.tempEnabled==true end
   if message.energyEnabled~=nil then ENERGY_SHUTDOWN_ENABLED=message.energyEnabled==true end
   if message.tempStartEnabled~=nil then AUTO_START_TEMP_ENABLED=message.tempStartEnabled==true end
   if message.energyStartEnabled~=nil then AUTO_START_ENERGY_ENABLED=message.energyStartEnabled==true end
   if message.tempMin~=nil then TEMP_MIN=tonumber(message.tempMin) or TEMP_MIN end
   if message.tempMax~=nil then TEMP_MAX=tonumber(message.tempMax) or TEMP_MAX end
   if message.energyMin~=nil then ENERGY_MIN=tonumber(message.energyMin) or ENERGY_MIN end
   if message.energyMax~=nil then ENERGY_MAX=tonumber(message.energyMax) or ENERGY_MAX end
   saveConfig(); setLog("SICHERHEITSEINSTELLUNGEN GESPEICHERT"); sendStatus(senderAddress)
  end
 end
end

if gpu and screen then drawFrame() end
refreshSG(); refreshGUI()
local last=0
while true do
 local ev,a,b,c,d,e=event.pullMultiple(0.5,"modem_message","touch")
 if ev=="modem_message" then packet(a,b,c,d,e)
 elseif ev=="touch" then touch(tonumber(b) or 0,tonumber(c) or 0) end
 local now=computer.uptime()
 if now-last>1 then
  last=now; refreshSG(); if reactor.online and now-reactor.lastSeen>4 then reactor.online=false end; autoControl(); refreshGUI()
 end
end
