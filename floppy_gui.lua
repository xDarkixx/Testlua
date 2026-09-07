-- Testlua Floppy Center
-- Universal OpenComputers GUI for BACKUP / RESTORE / STATUS.
-- Uses the current working/home directory; no hard-coded user path.

local component = require("component")
local event = require("event")
local term = require("term")
local unicode = require("unicode")
local shell = require("shell")
local computer = require("computer")

local gpu = component.gpu
local fs = component.isAvailable("filesystem") and component.getPrimary("filesystem") or nil
local cwd = shell.getWorkingDirectory() or "/"

local function role()
  if component.isAvailable("br_reactor") then return "REACTOR", "TESTLUA-REACTOR" end
  if component.isAvailable("stargate") then return "STARGATE", "TESTLUA-STARGATE" end
  if component.isAvailable("modem") then return "SERVER", "TESTLUA-SERVER" end
  return "SYSTEM", "TESTLUA-SYSTEM"
end

local ROLE, LABEL = role()
local W,H = gpu.maxResolution()
W,H = math.min(W,80), math.min(H,25)
gpu.setResolution(W,H)

local C_BG=0x05070A
local C_PANEL=0x0E121A
local C_BORDER=0x1A2332
local C_TEXT=0xECF0F1
local C_MUTED=0x4A5868
local C_CYAN=0x00E5FF
local C_GREEN=0x2ECC71
local C_RED=0xE74C3C
local C_YELLOW=0xF1C40F

local function button(x,y,w,h,text,bg,fg)
  gpu.setBackground(bg); gpu.fill(x,y,w,h," ")
  gpu.setForeground(fg or C_TEXT)
  gpu.set(x+math.floor((w-unicode.len(text))/2),y+math.floor(h/2),text)
end

local function disk()
  if not component.isAvailable("filesystem") then return nil end
  local primary=component.getPrimary("filesystem")
  for addr in component.list("filesystem") do
    if not primary or addr ~= primary.address then
      local d=component.proxy(addr)
      local label=(d.getLabel and d.getLabel()) or ""
      local total=(d.spaceTotal and d.spaceTotal()) or 0
      if label==LABEL and not (d.isReadOnly and d.isReadOnly()) then return d end
      if label=="" and total>0 and total<=2000000 and not (d.isReadOnly and d.isReadOnly()) then
        if d.setLabel then pcall(d.setLabel,LABEL) end
        return d
      end
    end
  end
  return nil
end

local function draw(status)
  gpu.setBackground(C_BG); term.clear()
  gpu.setForeground(C_CYAN); gpu.set(3,2,"◈ TESTLUA FLOPPY CENTER")
  gpu.setForeground(C_MUTED); gpu.set(3,3,"SYSTEM: "..ROLE.."    LABEL: "..LABEL)
  gpu.setBackground(C_PANEL); gpu.fill(2,5,W-3,14," ")
  gpu.setForeground(C_BORDER); gpu.fill(2,5,W-3,1,"━")
  gpu.setForeground(C_TEXT); gpu.set(5,7,"BACKUP / RESTORE")
  button(5,9,20,3,"[ BACKUP ]",C_CYAN,C_BG)
  button(28,9,20,3,"[ RESTORE ]",C_GREEN,C_BG)
  button(51,9,20,3,"[ STATUS ]",C_BORDER,C_TEXT)
  button(5,14,20,3,"[ INSTALLER ]",C_BORDER,C_TEXT)
  button(28,14,20,3,"[ HOME ]",C_BORDER,C_TEXT)
  button(51,14,20,3,"[ EXIT ]",C_RED,C_TEXT)
  gpu.setForeground(C_YELLOW); gpu.set(5,18,"STATUS: "..(status or "READY"))
  gpu.setForeground(C_MUTED); gpu.set(5,20,"Backup-Ziel ist immer das aktuelle Arbeits-/Home-Verzeichnis.")
  gpu.set(5,21,"Keine fest eingetragenen Benutzerpfade.")
end

local function run(cmd)
  draw(cmd.." ...")
  os.sleep(0.1)
  local p=shell.resolve("floppy_backup.lua")
  if p then
    local ok,err=pcall(function() shell.execute(p.." "..cmd) end)
    if ok then return "Fertig: "..cmd else return "Fehler: "..tostring(err) end
  end
  return "floppy_backup.lua nicht gefunden"
end

draw("READY - Floppy einlegen")
while true do
  local e,_,x,y=event.pull("touch")
  if e=="touch" then
    if y>=9 and y<=11 and x>=5 and x<=25 then
      draw(run("backup"))
    elseif y>=9 and y<=11 and x>=28 and x<=48 then
      draw(run("restore"))
    elseif y>=9 and y<=11 and x>=51 and x<=71 then
      local d=disk()
      draw(d and ("Floppy OK: "..tostring(d.getLabel and d.getLabel() or "")) or "Keine passende Floppy")
    elseif y>=14 and y<=16 and x>=5 and x<=25 then
      local p=shell.resolve("floppy_installer.lua")
      if p then shell.execute(p) else draw("Installer nicht gefunden") end
    elseif y>=14 and y<=16 and x>=28 and x<=48 then
      draw("HOME: "..cwd)
    elseif y>=14 and y<=16 and x>=51 and x<=71 then
      break
    end
  end
end

gpu.setBackground(0x000000); term.clear()
