-- TESTLUA SERVER - OpenComputers 1.7.10
-- Server fuer Reactor + SGCraft. GUI wird nur bei echten Aenderungen aktualisiert.
local component = require("component")
local event = require("event")
local serialization = require("serialization")
local fs = require("filesystem")
local shell = require("shell")

if not component.isAvailable("modem") then
  io.stderr:write("Fehler: Modem fehlt!\n")
  return
end

local modem = component.modem
local gpu = component.isAvailable("gpu") and component.gpu or nil
local screen = component.isAvailable("screen") and component.screen or nil
local PORT_REAKTOR, PORT_REMOTE = 101, 102
modem.open(PORT_REAKTOR)
modem.open(PORT_REMOTE)

local currentDir = shell.getWorkingDirectory() or "/"
local SAVE_FILE = fs.concat(currentDir, "reactor_config.dat")
local AUTO_SENSOR = "TEMP"
local SCHWELLE_AN, SCHWELLE_AUS = 10, 90
local TEMP_MIN, TEMP_MAX = 750, 1000
local ENERGY_MIN, ENERGY_MAX = 20, 90
local ROD_MIN, ROD_MAX, ROD_STEP = 0, 100, 5
local gesamtRF_Erzeugt, MODUS, steuerstabZiel = 0, "AUTO", 0
local signalStaerke = 400
local lastDaten, graphHistory = {}, {}
for i=1,24 do graphHistory[i]=0 end
if modem.setStrength then pcall(modem.setStrength, signalStaerke) end

local function clamp(v,lo,hi)
  v=tonumber(v) or lo
  if v<lo then return lo end
  if v>hi then return hi end
  return v
end

local function saveConfig()
  pcall(function()
    local f=io.open(SAVE_FILE,"w")
    if f then
      f:write(serialization.serialize({an=SCHWELLE_AN,aus=SCHWELLE_AUS,tempMin=TEMP_MIN,tempMax=TEMP_MAX,energyMin=ENERGY_MIN,energyMax=ENERGY_MAX,autoSensor=AUTO_SENSOR,rods=steuerstabZiel,rodMin=ROD_MIN,rodMax=ROD_MAX,rodStep=ROD_STEP,rf=gesamtRF_Erzeugt,strength=signalStaerke}))
      f:close()
    end
  end)
end

local function loadConfig()
  if not fs.exists(SAVE_FILE) then return end
  local f=io.open(SAVE_FILE,"r")
  if not f then return end
  local text=f:read("*all") or ""; f:close()
  local ok,d=pcall(serialization.unserialize,text)
  if not ok or type(d)~="table" then return end
  SCHWELLE_AN=clamp(d.an,0,100); SCHWELLE_AUS=clamp(d.aus,SCHWELLE_AN,100)
  TEMP_MIN=math.max(1,tonumber(d.tempMin) or 750); TEMP_MAX=math.max(TEMP_MIN+1,tonumber(d.tempMax) or 1000)
  ENERGY_MIN=clamp(d.energyMin,0,100); ENERGY_MAX=clamp(d.energyMax,ENERGY_MIN,100)
  local s=tostring(d.autoSensor or "TEMP"); AUTO_SENSOR=(s=="ENERGY" or s=="HYBRID") and s or "TEMP"
  ROD_MIN=clamp(d.rodMin,0,100); ROD_MAX=clamp(d.rodMax,ROD_MIN,100); ROD_STEP=clamp(d.rodStep,1,25)
  steuerstabZiel=clamp(d.rods,ROD_MIN,ROD_MAX); gesamtRF_Erzeugt=math.max(0,tonumber(d.rf) or 0)
  signalStaerke=clamp(d.strength,1,400)
  if modem.setStrength then pcall(modem.setStrength,signalStaerke) end
end

local function getStargate()
  if not component.isAvailable("stargate") then return nil end
  local ok,sg=pcall(component.getPrimary,"stargate")
  if ok and sg then return sg end
  return nil
end

local function getStargateData()
  local sg=getStargate()
  if not sg then return "NO GATE",0,"N/A","N/A" end
  local state,chev,iris,addr="UNKNOWN",0,"UNKNOWN","N/A"
  pcall(function()
    if sg.stargateState then
      local a,b=sg.stargateState(); state=a or state; chev=tonumber(b) or 0
    end
    if sg.irisState then iris=sg.irisState() or iris end
    if sg.localAddress then addr=sg.localAddress() or addr end
  end)
  return tostring(state),chev,tostring(iris),tostring(addr)
end

local function rodCount(payload)
  return math.max(1,math.floor(tonumber(payload and payload.rodCount) or 1))
end

local function sendReactorCommand(address,cmd,target,payload)
  local count=rodCount(payload); local levels={}
  target=clamp(target or steuerstabZiel,ROD_MIN,ROD_MAX)
  for i=0,count-1 do levels[i]=target end
  modem.send(address,PORT_REAKTOR,serialization.serialize({befehl=cmd,rods=target,rodLevels=levels,rodStep=ROD_STEP}))
end

local function setAutoValue(cmd,value)
  if cmd=="SET_AUTO_SENSOR" then
    local s=tostring(value or "")
    if s~="TEMP" and s~="ENERGY" and s~="HYBRID" then return false end
    AUTO_SENSOR=s; saveConfig(); return true
  end
  value=tonumber(value); if not value then return false end
  if cmd=="SET_TEMP_MIN" then TEMP_MIN=math.max(1,math.min(TEMP_MAX-1,value))
  elseif cmd=="SET_TEMP_MAX" then TEMP_MAX=math.max(TEMP_MIN+1,value)
  elseif cmd=="SET_ENERGY_MIN" then ENERGY_MIN=clamp(value,0,ENERGY_MAX-1)
  elseif cmd=="SET_ENERGY_MAX" then ENERGY_MAX=clamp(value,ENERGY_MIN+1,100)
  elseif cmd=="SET_ROD_MIN" then ROD_MIN=clamp(value,0,ROD_MAX); steuerstabZiel=math.max(steuerstabZiel,ROD_MIN)
  elseif cmd=="SET_ROD_MAX" then ROD_MAX=clamp(value,ROD_MIN,100); steuerstabZiel=math.min(steuerstabZiel,ROD_MAX)
  elseif cmd=="SET_ROD_STEP" then ROD_STEP=clamp(value,1,25)
  else return false end
  saveConfig(); return true
end

local function autoControl(p)
  local temp=tonumber(p.tempKern) or 0; local energy=clamp(p.prozent,0,100); local active=not not p.istAktiv
  local target=clamp(steuerstabZiel,ROD_MIN,ROD_MAX)
  if not active then
    if AUTO_SENSOR=="TEMP" and temp<=TEMP_MIN then return "AN",target end
    if AUTO_SENSOR=="ENERGY" and energy<=ENERGY_MIN then return "AN",target end
    if AUTO_SENSOR=="HYBRID" and temp<=TEMP_MIN and energy<=ENERGY_MIN then return "AN",target end
    return "PING",target
  end
  if temp>=TEMP_MAX then return "AUS",ROD_MAX end
  if AUTO_SENSOR=="TEMP" or AUTO_SENSOR=="HYBRID" then
    if temp>=TEMP_MAX-50 then target=math.min(ROD_MAX,target+ROD_STEP)
    elseif temp<=TEMP_MIN then target=math.max(ROD_MIN,target-ROD_STEP) end
  end
  if AUTO_SENSOR=="ENERGY" or AUTO_SENSOR=="HYBRID" then
    if energy>=ENERGY_MAX then target=math.min(ROD_MAX,target+ROD_STEP)
    elseif energy<=ENERGY_MIN then target=math.max(ROD_MIN,target-ROD_STEP) end
  end
  return "PING",target
end

-- GUI: statischer Rahmen wird nur einmal gezeichnet; danach werden nur Datenzeilen erneuert.
local guiReady=false
local guiW,guiH=0,0
local function guiLine(y,text)
  if not guiReady then return end
  gpu.setForeground(0xFFFFFF); gpu.setBackground(0x101820)
  gpu.fill(2,y,guiW-2,1," "); gpu.set(2,y,tostring(text):sub(1,math.max(1,guiW-2)))
end

local function drawButton(x,y,w,text)
  gpu.setBackground(0x202830); gpu.setForeground(0xFFFFFF); gpu.fill(x,y,w,1," "); gpu.set(x+1,y,"[ "..text.." ]")
end

local function initGUI()
  if not gpu or not screen then return end
  local ok=pcall(gpu.bind,screen.address); if not ok then return end
  guiW,guiH=gpu.getResolution(); if guiW<50 or guiH<12 then return end
  gpu.setBackground(0x101820); gpu.setForeground(0xFFFFFF); gpu.fill(1,1,guiW,guiH," ")
  gpu.setForeground(0x00FFFF); gpu.set(2,2,"TESTLUA SERVER")
  gpu.setForeground(0xAAAAAA); gpu.set(2,3,"Zentraler SGC / BigReactors Controller")
  gpu.setForeground(0xFFFFFF); gpu.set(2,5,"STATUS: ONLINE")
  gpu.set(2,6,"MODEM: ONLINE   PORT 101: REAKTOR   PORT 102: REMOTE")
  drawButton(2,guiH-2,13,"BACKUP"); drawButton(17,guiH-2,14,"RESTORE"); drawButton(33,guiH-2,13,"STATUS")
  gpu.setForeground(0x777777); gpu.set(2,guiH,"TESTLUA SERVER - Modem-Dienst aktiv")
  guiReady=true
end

local function refreshGUI(message)
  if not guiReady then return end
  guiLine(7,"MODUS: "..MODUS.."   AUTO: "..AUTO_SENSOR.."   STÄBE: "..tostring(steuerstabZiel).."%")
  local p=tonumber(lastDaten.prozent); local t=tonumber(lastDaten.tempKern)
  guiLine(8,"REAKTOR: "..(lastDaten.istAktiv and "AKTIV" or "WARTET").."   TEMP: "..(t and string.format("%.1fK",t) or "--").."   ENERGY: "..(p and string.format("%.1f%%",p) or "--"))
  local state,chev,iris,addr=getStargateData()
  guiLine(9,"STARGATE: "..state.."   CHEVRONS: "..chev.."   IRIS: "..iris)
  guiLine(10,"ADDRESS: "..addr)
  if message then gpu.setForeground(0xFFFF00); gpu.setBackground(0x101820); gpu.fill(2,guiH-3,guiW-2,1," "); gpu.set(2,guiH-3,tostring(message):sub(1,guiW-2)) end
end

loadConfig(); initGUI(); refreshGUI("Server gestartet")

while true do
  local ev,a,b,c,d,e=event.pullMultiple(1.0,"modem_message","touch")

  if ev=="touch" and guiReady then
    -- OpenComputers: touch, screenAddress, x, y, button, user
    local x=tonumber(b); local y=tonumber(c)
    if x and y and y==guiH-2 then
      if x>=2 and x<=14 then
        refreshGUI("Backup läuft...")
        shell.execute("floppy_backup.lua backup")
        refreshGUI("Backup fertig")
      elseif x>=17 and x<=31 then
        refreshGUI("Restore läuft...")
        shell.execute("floppy_backup.lua restore")
        refreshGUI("Restore fertig")
      elseif x>=33 and x<=46 then
        refreshGUI("Status aktualisiert")
      end
    end

  elseif ev=="modem_message" then
    local senderAddress=a; local port=b; local message=e
    if message and tostring(message)~="" then
      local ok,p=pcall(serialization.unserialize,tostring(message))
      if ok and type(p)=="table" then
        if port==PORT_REAKTOR and p.prozent~=nil then
          lastDaten=p
          if p.istAktiv then gesamtRF_Erzeugt=gesamtRF_Erzeugt+((tonumber(p.rfProTick) or 0)*20) end
          table.remove(graphHistory,1); table.insert(graphHistory,tonumber(p.rfProTick) or 0)
          local cmd="PING"
          if MODUS=="AUTO" then cmd,steuerstabZiel=autoControl(p)
          elseif MODUS=="MANUELL_AN" then cmd="AN"
          elseif MODUS=="MANUELL_AUS" then cmd="AUS" end
          steuerstabZiel=clamp(steuerstabZiel,ROD_MIN,ROD_MAX)
          sendReactorCommand(senderAddress,cmd,steuerstabZiel,p)
          saveConfig(); refreshGUI()

        elseif port==PORT_REMOTE and p.cmd then
          local cmd=tostring(p.cmd)
          if cmd=="GET_DATA" then
            local sgState,sgChevrons,sgIris,sgAddr=getStargateData()
            modem.send(senderAddress,PORT_REMOTE,serialization.serialize({lastDaten=lastDaten,graphHistory=graphHistory,gesamtRF=gesamtRF_Erzeugt,an=SCHWELLE_AN,aus=SCHWELLE_AUS,tempMin=TEMP_MIN,tempMax=TEMP_MAX,temp=TEMP_MAX,energyMin=ENERGY_MIN,energyMax=ENERGY_MAX,autoSensor=AUTO_SENSOR,rods=steuerstabZiel,rodMin=ROD_MIN,rodMax=ROD_MAX,rodStep=ROD_STEP,modus=MODUS,sgState=sgState,sgChevrons=sgChevrons,sgIris=sgIris,sgAddr=sgAddr}))
          elseif cmd=="SET_TEMP_MIN" or cmd=="SET_TEMP_MAX" or cmd=="SET_ENERGY_MIN" or cmd=="SET_ENERGY_MAX" or cmd=="SET_ROD_MIN" or cmd=="SET_ROD_MAX" or cmd=="SET_ROD_STEP" or cmd=="SET_AUTO_SENSOR" then
            setAutoValue(cmd,p.val); refreshGUI("Einstellung gespeichert")
          elseif cmd=="SET_RODS" then steuerstabZiel=clamp(p.val,ROD_MIN,ROD_MAX); saveConfig(); refreshGUI()
          elseif cmd=="RODS_DOWN" then steuerstabZiel=math.min(ROD_MAX,steuerstabZiel+ROD_STEP); saveConfig(); refreshGUI()
          elseif cmd=="RODS_UP" then steuerstabZiel=math.max(ROD_MIN,steuerstabZiel-ROD_STEP); saveConfig(); refreshGUI()
          elseif cmd=="SET_MODUS" then
            local m=tostring(p.val or "AUTO")
            if m=="AUTO" or m=="MANUELL_AN" or m=="MANUELL_AUS" then MODUS=m; saveConfig(); refreshGUI() end
          else
            local sg=getStargate()
            if sg then
              if cmd=="SG_IRIS_OPEN" and sg.openIris then pcall(sg.openIris)
              elseif cmd=="SG_IRIS_CLOSE" and sg.closeIris then pcall(sg.closeIris)
              elseif cmd=="SG_DISCONNECT" and sg.disconnect then pcall(sg.disconnect)
              elseif cmd=="SG_DIAL" and sg.dial and type(p.val)=="string" then pcall(sg.dial,p.val) end
              refreshGUI("Stargate-Befehl: "..cmd)
            else
              refreshGUI("Kein Stargate gefunden")
            end
          end
        end
      end
    end
  end
end
