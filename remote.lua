local component = require("component")
local event = require("event")
local serialization = require("serialization")
local term = require("term")
local computer = require("computer")
local unicode = require("unicode")
local shell = require("shell")
local fs = require("filesystem")

-- Testlua SGC Remote
-- OpenComputers 1.7.10 / SGCraft 1.13.3
-- Design intentionally kept in the existing SGC command-center style.

if not component.isAvailable("modem") or not component.isAvailable("gpu") then
  io.stderr:write("Fehler: Modem und GPU werden benötigt.\n")
  return
end

local modem = component.modem
local gpu = component.gpu
local PORT = 102
pcall(modem.open, PORT)
if modem.setStrength then pcall(modem.setStrength, 400) end

local mw,mh = gpu.maxResolution()
local W,H = math.min(120,mw), math.min(35,mh)
pcall(gpu.setResolution,W,H)

local CURRENT_TAB = "STARGATE"
local serverAddress = nil
local currentDir = shell.getWorkingDirectory() or "/"
local ADDRESS_FILE = fs.concat(currentDir,"sgc_adressbuch.dat")
local ADRESSBUCH = {
 {name="P3X-982 (ERDE ALPHA)",addr="SGCBASE",glyphen="TAURUS / VIRGO / ORION / EARTH"},
 {name="ABYDOS REBELLEN-AUSSENPOSTEN",addr="ABYDOSX",glyphen="CRATER / SERPENS / ARIES / EARTH"},
 {name="ATLANTIS KONTROLL-RAUM",addr="ATLANTN",glyphen="PEGASUS / ANDROMEDA / CETUS / EARTH"}
}

local C_BG=0x05070A
local C_PANEL=0x0E121A
local C_BORDER=0x1A2332
local C_TEXT=0xECF0F1
local C_MUTED=0x4A5868
local C_GREEN=0x2ECC71
local C_YELLOW=0xF1C40F
local C_RED=0xE74C3C
local C_CYAN=0x00E5FF
local C_PURPLE=0x9B59B6
local C_RING=0x546E7A
local C_OFF=0x1C2B38
local C_LOCK=0xFF9800
local C_ON=0xFF3D00
local C_KAWOOSH=0x00B0FF

local GLYPH_CODES={[1]="EARTH",[2]="CRATER",[3]="VIRGO",[4]="BOOTES",[5]="CENTAUR",[6]="LIBRA",[7]="SERPENS",[8]="SCORPIO",[9]="CORONA",[10]="LUPUS",[11]="NORMA",[12]="OPHIUCH",[13]="SAGITT",[14]="COR.AUS",[15]="SCUTUM",[16]="CAPRIC",[17]="MICROS",[18]="SCULPT",[19]="PISC.A",[20]="AQUAR.",[21]="PEGASUS",[22]="EQUUL.",[23]="ARIES",[24]="CETUS",[25]="PISCES",[26]="ANDROM",[27]="TRIANG",[28]="TAURUS",[29]="PERSEU",[30]="AURIGA",[31]="ERIDAN",[32]="ORION",[33]="MONOC.",[34]="GEMINI",[35]="CAN.MAJ",[36]="PUPPIS",[37]="CANCER",[38]="HYDRA",[39]="LYNX"}
local DIAL_SEQUENCE={28,3,32,5,12,18,1}

local lastServerData={}
local statusText="SGC DIALING SYSTEM READY"
local dirty=true
local nextRequest=0
local nextAnimation=0
local ringAngle=0
local direction=1
local lastChevron=0
local animFrame=0
local kawooshFrame=0

local function saveAddresses()
 local f=io.open(ADDRESS_FILE,"w")
 if not f then return false end
 local ok=pcall(function() f:write(serialization.serialize(ADRESSBUCH)); f:close() end)
 return ok
end

local function loadAddresses()
 if not fs.exists(ADDRESS_FILE) then return end
 local f=io.open(ADDRESS_FILE,"r"); if not f then return end
 local raw=f:read("*all") or ""; f:close()
 local ok,data=pcall(serialization.unserialize,raw)
 if not ok or type(data)~="table" then return end
 local clean={}
 for _,v in ipairs(data) do
  if type(v)=="table" and type(v.name)=="string" and type(v.addr)=="string" then
   table.insert(clean,{name=v.name,addr=v.addr,glyphen=tostring(v.glyphen or "")})
  end
 end
 if #clean>0 then ADRESSBUCH=clean end
end

local function setStatus(t)
 statusText=tostring(t or "")
 dirty=true
end

local function sendPacket(packet)
 local data=serialization.serialize(packet)
 local sent=false
 if serverAddress and modem.send then
  local ok=pcall(modem.send,serverAddress,PORT,data)
  sent=ok
 end
 if not sent then
  pcall(modem.broadcast,PORT,data)
 end
end

local function requestData()
 sendPacket({cmd="GET_DATA"})
end

local function command(cmd,val)
 local p={cmd=cmd}
 if val~=nil then p.val=val end
 sendPacket(p)
 setStatus("SENDE: "..cmd)
 -- A second broadcast is intentionally delayed through the normal request timer.
 nextRequest=computer.uptime()+0.35
end

local function drawBox(x,y,w,h,title,titleColor)
 gpu.setBackground(C_PANEL); gpu.fill(x,y,w,h," ")
 gpu.setForeground(C_BORDER)
 gpu.fill(x,y,w,1,"━"); gpu.fill(x,y+h-1,w,1,"━")
 for i=0,h-1 do gpu.set(x,y+i,"┃"); gpu.set(x+w-1,y+i,"┃") end
 gpu.set(x,y,"┏"); gpu.set(x+w-1,y,"┓"); gpu.set(x,y+h-1,"┗"); gpu.set(x+w-1,y+h-1,"┛")
 if title then gpu.setForeground(titleColor or C_CYAN); gpu.set(x+3,y,"┤ "..title.." ├") end
end

local function drawButton(x,y,w,h,text,bg,fg)
 gpu.setBackground(bg); gpu.fill(x,y,w,h," ")
 gpu.setForeground(fg or C_TEXT)
 local px=x+math.max(0,math.floor((w-unicode.len(text))/2))
 gpu.set(px,y+math.floor(h/2),text)
end

local function drawGate(x,y,state,chevrons)
 local active=tonumber(chevrons) or 0
 if tostring(state)=="Connected" then active=7 end
 local locking=active>lastChevron and active<=7
 if locking then
  lastChevron=active
  direction=(active%2==0) and 1 or -1
 end
 if state=="Idle" or state=="No Gate" or state=="Offline" then
  lastChevron=0; ringAngle=0
 elseif state=="Dialling" then
  ringAngle=(ringAngle+direction*3)%360
 end

 gpu.setBackground(C_PANEL); gpu.setForeground(C_RING)
 gpu.set(x+10,y+1,"⢀⣀⣤⣤⣤⣤⣤⣤⣤⣤⣀⡀")
 gpu.set(x+5,y+2,"⣠⣾⠿⠉⠉        ⠉⠉⠿⣷⣄")
 gpu.set(x+3,y+3,"⣵⡿⠁                ⠈⢿⣦")
 gpu.set(x+1,y+4,"⣾⡿                     ⢿⣷")
 gpu.set(x,y+5,"⣿⡇                     ⢸⣿")
 gpu.set(x,y+6,"⣿⡇                     ⢸⣿")
 gpu.set(x,y+7,"⣿⡇                     ⢸⣿")
 gpu.set(x+1,y+8,"⢿⣷                     ⣾⡿")
 gpu.set(x+3,y+9,"⠹⣷⣄                ⣠⣾⠏")
 gpu.set(x+5,y+10,"⠈⠻⢿⣦⣤⣀        ⣀⣤⣴⠿⠟⠁")
 gpu.set(x+10,y+11,"⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉")

 gpu.setForeground(active>=7 and C_ON or (locking and C_LOCK or C_OFF))
 gpu.set(x+16,y,"[ CHEVRON 7 ]")
 local pos={{x+25,y+3},{x+27,y+6},{x+25,y+9},{x+1,y+9},{x-1,y+6},{x+1,y+3}}
 for i,p in ipairs(pos) do
  if i<=active then gpu.setForeground(C_ON); gpu.set(p[1],p[2],"["..(GLYPH_CODES[DIAL_SEQUENCE[i]] or "LOCK").."]")
  elseif state=="Dialling" and i==active+1 then gpu.setForeground(C_YELLOW); gpu.set(p[1],p[2],(animFrame%2==0) and "[SEARCH]" or "[======]")
  else gpu.setForeground(C_OFF); gpu.set(p[1],p[2],"[------]") end
 end
 if state=="Connected" then
  kawooshFrame=(kawooshFrame+1)%3
  local wav=(kawooshFrame==0 and "≈~≈~≈~≈~≈~") or (kawooshFrame==1 and "~≈~≈~≈~≈~≈") or "▒░▒░▒░▒░▒░"
  gpu.setBackground(C_KAWOOSH); gpu.setForeground(0xFFFFFF)
  gpu.set(x+8,y+5," "..wav.." "); gpu.set(x+7,y+6,"  WURMLOCH AKTIV  "); gpu.set(x+8,y+7," "..wav.." ")
 end
 gpu.setBackground(C_PANEL); gpu.setForeground(C_MUTED); gpu.set(x+2,y+13,"SGC Passierende Glyphe:")
 local gi=(math.floor(ringAngle/(360/39))%39)+1
 gpu.setForeground(C_CYAN); gpu.set(x+25,y+13,string.format("[%02d] %s",gi,GLYPH_CODES[gi] or "UNKNOWN"))
end

local function render()
 gpu.setBackground(C_BG); term.clear()
 gpu.setBackground(C_PANEL); gpu.fill(1,1,W,3," ")
 gpu.setForeground(C_CYAN); gpu.set(3,2,"◈ SGC COMMAND CENTER - COMPUTER DIALING PROGRAM")
 drawButton(50,2,18,1,"[ REAKTOR ]",CURRENT_TAB=="REAKTOR" and C_CYAN or C_BORDER,C_TEXT)
 drawButton(70,2,18,1,"[ STARGATE DHD ]",CURRENT_TAB=="STARGATE" and C_PURPLE or C_BORDER,C_TEXT)

 local s=lastServerData
 if CURRENT_TAB=="STARGATE" then
  drawBox(2,5,62,24,"SGC CHEVRON & SYMBOL TELEMETRIE",C_CYAN)
  drawGate(5,6,s.sgState or "Offline",s.sgChevrons or 0)
  drawBox(38,7,23,5,"SGC LOG",C_YELLOW)
  gpu.setBackground(C_PANEL); gpu.setForeground(C_YELLOW)
  gpu.set(40,9,string.sub(statusText,1,19)); gpu.set(40,10,string.sub(statusText,20,38))
  drawButton(38,14,23,2,"IRIS ÖFFNEN",C_GREEN,C_BG)
  drawButton(38,17,23,2,"IRIS SCHLIESSEN",C_RED,C_TEXT)
  drawButton(38,20,23,2,"ABBRECHEN",C_BORDER,C_TEXT)
  drawBox(66,5,52,24,"DHD COMPUTER DIALING (SGC)",C_PURPLE)
  for i=1,math.min(3,#ADRESSBUCH) do
   local e=ADRESSBUCH[i]; local yy=7+(i-1)*6
   drawBox(68,yy,48,5,e.name,C_CYAN)
   gpu.setBackground(C_PANEL); gpu.setForeground(C_MUTED); gpu.set(70,yy+2,string.sub(e.glyphen,1,18))
   drawButton(89,yy+1,12,3,"WÄHLEN",C_PURPLE,C_TEXT)
   drawButton(102,yy+1,12,3,"EDIT",C_BORDER,C_TEXT)
  end
 else
  drawBox(2,5,116,24,"REAKTOR CONTROL",C_CYAN)
  local r=s.lastDaten or {}
  gpu.setBackground(C_PANEL); gpu.setForeground(C_TEXT)
  gpu.set(5,8,"STATUS: "..(s.reactorOnline and (s.reactorActive and "AKTIV" or "AUS") or "OFFLINE"))
  gpu.set(5,10,string.format("TEMPERATUR: %.1f",tonumber(r.tempKern or s.temp or 0)))
  gpu.set(5,12,string.format("ENERGIE: %.1f %%",tonumber(r.prozent or 0)))
  gpu.set(5,14,string.format("STEUERSTÄBE: %.0f %%",tonumber(r.steuerstaebe or s.rods or 0)))
  drawButton(70,8,20,2,"STÄBE -5",C_BORDER,C_TEXT)
  drawButton(92,8,20,2,"STÄBE +5",C_BORDER,C_TEXT)
  drawButton(70,12,20,2,"AUTO",C_CYAN,C_BG)
  drawButton(92,12,20,2,"START",C_GREEN,C_BG)
  drawButton(81,16,20,2,"STOPP",C_RED,C_TEXT)
 end

 gpu.setBackground(C_BG); gpu.setForeground(C_MUTED)
 gpu.set(2,H-2,"SERVER: "..(serverAddress and "VERBUNDEN" or "BROADCAST").." | STATUS: "..string.sub(statusText,1,55))
end

local function inside(x,y,x1,y1,x2,y2)
 return x>=x1 and x<=x2 and y>=y1 and y<=y2
end

local function touch(x,y)
 x=tonumber(x) or 0; y=tonumber(y) or 0
 -- Tabs
 if inside(x,y,50,1,68,3) then CURRENT_TAB="REAKTOR"; dirty=true; return end
 if inside(x,y,70,1,88,3) then CURRENT_TAB="STARGATE"; dirty=true; return end

 if CURRENT_TAB=="STARGATE" then
  if inside(x,y,38,14,60,15) then command("SG_IRIS_OPEN"); return end
  if inside(x,y,38,17,60,18) then command("SG_IRIS_CLOSE"); return end
  if inside(x,y,38,20,60,21) then command("SG_DISCONNECT"); return end
  for i=1,math.min(3,#ADRESSBUCH) do
   local yy=7+(i-1)*6
   if inside(x,y,89,yy+1,100,yy+3) then
    command("SG_DIAL",ADRESSBUCH[i].addr)
    return
   end
   if inside(x,y,102,yy+1,113,yy+3) then
    setStatus("EDIT NICHT PER TOUCH - TASTATUR")
    return
   end
  end
 else
  if inside(x,y,70,8,89,9) then command("RODS_UP"); return end
  if inside(x,y,92,8,111,9) then command("RODS_DOWN"); return end
  if inside(x,y,70,12,89,13) then command("AUTO"); return end
  if inside(x,y,92,12,111,13) then command("AN"); return end
  if inside(x,y,81,16,100,17) then command("AUS"); return end
 end
end

local function handleEvent(ev,a,b,c,d,e)
 if ev=="touch" then
  -- OpenComputers: touch, screenAddress, x, y, button, user
  touch(b,c)
 elseif ev=="modem_message" then
  -- OpenComputers: modem_message, localAddress, remoteAddress, port, distance, message
  local port=tonumber(c)
  if port==PORT and e then
   serverAddress=b
   local ok,data=pcall(serialization.unserialize,tostring(e))
   if ok and type(data)=="table" then
    lastServerData=data
    if data.log and tostring(data.log)~="" then statusText=tostring(data.log) end
    dirty=true
   end
  end
 elseif ev=="key_down" then
  -- Keyboard fallback: 28=Enter on standard OC keyboards.
  local code=tonumber(c) or 0
  if code==28 then requestData() end
 end
end

loadAddresses()
render()
requestData()
nextRequest=computer.uptime()+1

while true do
 local ev,a,b,c,d,e=event.pull(0.05)
 if ev then handleEvent(ev,a,b,c,d,e) end
 local now=computer.uptime()

 if now>=nextRequest then
  requestData()
  nextRequest=now+2.0
 end

 local state=tostring(lastServerData.sgState or "")
 if state=="Dialling" or state=="Connected" then
  if now>=nextAnimation then
   animFrame=(animFrame+1)%4
   dirty=true
   nextAnimation=now+0.15
  end
 end

 if dirty then
  render()
  dirty=false
 end
end
