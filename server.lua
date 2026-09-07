-- Testlua Server Controller
-- OpenComputers 1.7.10 / SGCraft 1.13.3 / BigReactors 0.4.3A
-- Existing SGC film-style design is intentionally preserved.

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local filesystem = require("filesystem")
local shell = require("shell")
local os = require("os")

if not component.isAvailable("modem") then error("Testlua Server: Modem fehlt") end
local modem = component.modem
local gpu = component.isAvailable("gpu") and component.gpu or nil
local screen = component.isAvailable("screen") and component.screen or nil
if gpu and screen then pcall(gpu.bind, gpu, screen.address) end

local PORT_REACTOR, PORT_SERVER = 101, 102
pcall(modem.open, PORT_REACTOR); pcall(modem.open, PORT_SERVER)

local CONFIG_FILE="reactor_config.dat"
local AUTO_SENSOR="TEMP"
local TEMP_MIN,TEMP_MAX=750,1000
local ENERGY_MIN,ENERGY_MAX=20,90
local ROD_MIN,ROD_MAX,ROD_STEP=0,100,5
local reactor={online=false,active=false,temperature=0,energy=0,rods=0,rodLevels={},lastSeen=0}
local sg={proxy=nil,state="Offline",engaged=0,direction="",iris="UNKNOWN",address="N/A"}
local messageLog="SYSTEM BEREIT"
local guiDrawn=false

local function setLog(s) messageLog=tostring(s or "") end
local function saveConfig()
 local f=filesystem.open(CONFIG_FILE,"w"); if not f then return end
 f:write(serialization.serialize({sensor=AUTO_SENSOR,tempMin=TEMP_MIN,tempMax=TEMP_MAX,energyMin=ENERGY_MIN,energyMax=ENERGY_MAX,rodMin=ROD_MIN,rodMax=ROD_MAX,rodStep=ROD_STEP})); f:close()
end
local function loadConfig()
 if not filesystem.exists(CONFIG_FILE) then return end
 local f=filesystem.open(CONFIG_FILE,"r"); if not f then return end
 local d=f:read(math.huge); f:close(); local ok,t=pcall(serialization.unserialize,d)
 if ok and type(t)=="table" then
  AUTO_SENSOR=t.sensor or AUTO_SENSOR; TEMP_MIN=t.tempMin or TEMP_MIN; TEMP_MAX=t.tempMax or TEMP_MAX
  ENERGY_MIN=t.energyMin or ENERGY_MIN; ENERGY_MAX=t.energyMax or ENERGY_MAX
  ROD_MIN=t.rodMin or ROD_MIN; ROD_MAX=t.rodMax or ROD_MAX; ROD_STEP=t.rodStep or ROD_STEP
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
local function ensureSG()
 if not sg.proxy then sg.proxy=findStargate() end
 return sg.proxy
end
local function sgcall(method,...)
 local p=ensureSG(); if not p or type(p[method])~="function" then return false,nil end
 local ok,a,b,c=pcall(p[method],...); if not ok then setLog("SG FEHLER: "..tostring(a)); return false,nil end
 return true,{a,b,c}
end
local function refreshSG()
 if not ensureSG() then sg.state="Offline"; sg.iris="N/A"; sg.address="N/A"; return end
 local ok,r=sgcall("stargateState"); if ok and r then sg.state=tostring(r[1] or "Unknown"); sg.engaged=tonumber(r[2] or 0) or 0; sg.direction=tostring(r[3] or "") end
 local ok2,r2=sgcall("irisState"); if ok2 and r2 then sg.iris=tostring(r2[1] or "UNKNOWN") end
 local ok3,r3=sgcall("localAddress"); if ok3 and r3 then sg.address=tostring(r3[1] or "N/A") end
end
local function sgAction(method,arg)
 local p=ensureSG(); if not p then setLog("SG: INTERFACE NICHT GEFUNDEN"); return end
 local ok,err
 if arg~=nil then ok,err=pcall(p[method],arg) else ok,err=pcall(p[method]) end
 if not ok then setLog("SG FEHLER: "..tostring(err)) end
end
local function dialGate(addr) if not addr or addr=="" then setLog("SG: KEINE ADRESSE"); return end; sgAction("dial",addr); setLog("SG: WÄHLE "..addr) end
local function iris(open) sgAction(open and "openIris" or "closeIris"); setLog(open and "IRIS GEÖFFNET" or "IRIS GESCHLOSSEN") end
local function disconnectGate() sgAction("disconnect"); setLog("SG: VERBINDUNG GETRENNT") end
local function sendReactor(cmd,val) modem.broadcast(PORT_REACTOR,serialization.serialize({cmd=cmd,value=val})) end

local function drawFrame()
 if not gpu or not screen then return end
 local w,h=gpu.getResolution(); gpu.fill(1,1,w,h," ")
 gpu.set(2,1,"TESTLUA SERVER // SGC CONTROL")
 gpu.set(2,3,"[ REAKTOR ]   [ STARGATE ]")
 gpu.set(2,5,"REAKTOR TELEMETRIE"); gpu.set(2,6,"Status:      --------"); gpu.set(2,7,"Temperatur:  --------"); gpu.set(2,8,"Energy:      --------"); gpu.set(2,9,"Stäbe:       --------")
 gpu.set(2,11,"STARGATE TELEMETRIE"); gpu.set(2,12,"State:       --------"); gpu.set(2,13,"Chevron:     --------"); gpu.set(2,14,"Iris:        --------"); gpu.set(2,15,"Adresse:     --------")
 gpu.set(2,17,"[ IRIS AUF ] [ IRIS ZU ] [ TRENNEN ]"); gpu.set(2,19,"[ AUTO ] [ START ] [ STOPP ]"); gpu.set(2,21,"[ BACKUP ] [ RESTORE ] [ STATUS ]"); gpu.set(2,23,"LOG:"); gpu.set(2,24,messageLog)
 guiDrawn=true
end
local function line(y,t)
 if not gpu or not screen then return end
 local w,h=gpu.getResolution(); if y>h then return end
 gpu.fill(1,y,w,1," "); gpu.set(2,y,tostring(t):sub(1,math.max(1,w-3)))
end
local function refreshGUI()
 if not gpu or not screen then return end
 if not guiDrawn then drawFrame() end
 line(6,"Status:      "..(reactor.online and (reactor.active and "AKTIV" or "AUS") or "OFFLINE"))
 line(7,string.format("Temperatur:  %.1f C",reactor.temperature or 0)); line(8,string.format("Energy:      %.1f %%",reactor.energy or 0)); line(9,string.format("Stäbe:       %d",reactor.rods or 0))
 line(12,"State:       "..sg.state); line(13,"Chevron:     "..tostring(sg.engaged)); line(14,"Iris:        "..sg.iris); line(15,"Adresse:     "..sg.address); line(24,"LOG: "..messageLog)
end
local function touch(x,y)
 if y==17 then if x<18 then iris(true) elseif x<34 then iris(false) elseif x<55 then disconnectGate() end
 elseif y==19 then if x<14 then sendReactor("AUTO",true); setLog("REAKTOR: AUTO") elseif x<29 then sendReactor("AN",true); setLog("REAKTOR: START") elseif x<48 then sendReactor("AUS",true); setLog("REAKTOR: STOPP") end
 elseif y==21 then if x<15 then shell.execute("floppy_backup.lua","backup") elseif x<30 then shell.execute("floppy_backup.lua","restore") else shell.execute("floppy_backup.lua","status") end end
 refreshGUI()
end
local function packet(a,b,c,d,e)
 -- modem_message = event, localAddress, remoteAddress, port, distance, message
 local port=tonumber(c); local msg=e
 if port~=PORT_REACTOR and port~=PORT_SERVER then return end
 if type(msg)=="string" then local ok,p=pcall(serialization.unserialize,msg); if ok and type(p)=="table" then msg=p end end
 if type(msg)~="table" then return end
 if port==PORT_REACTOR then
  reactor.online=true; reactor.lastSeen=os.clock(); reactor.active=msg.active==true or msg.active==1
  reactor.temperature=tonumber(msg.temperature or msg.temp or 0) or 0; reactor.energy=tonumber(msg.energy or msg.energyPercent or 0) or 0; reactor.rods=tonumber(msg.rods or msg.rodLevel or 0) or 0
  if type(msg.rodLevels)=="table" then reactor.rodLevels=msg.rodLevels end
 elseif port==PORT_SERVER then
  if msg.cmd=="SG_DIAL" then dialGate(msg.address) elseif msg.cmd=="SG_IRIS_OPEN" then iris(true) elseif msg.cmd=="SG_IRIS_CLOSE" then iris(false) elseif msg.cmd=="SG_DISCONNECT" then disconnectGate() end
 end
end
if gpu and screen then drawFrame() end
refreshSG(); refreshGUI()
local last=0
while true do
 local ev,a,b,c,d,e=event.pullMultiple(0.5,"modem_message","touch")
 if ev=="modem_message" then packet(a,b,c,d,e) elseif ev=="touch" then touch(tonumber(b) or 0,tonumber(c) or 0) end
 if os.clock()-last>1 then last=os.clock(); refreshSG(); if reactor.online and os.clock()-reactor.lastSeen>4 then reactor.online=false end; refreshGUI() end
end
