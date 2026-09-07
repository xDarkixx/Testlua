local component = require("component")
local fs = require("filesystem")
local term = require("term")
local computer = require("computer")
local shell = require("shell")

if not component.isAvailable("filesystem") then
  io.stderr:write("Fehler: Kein Dateisystem oder Diskettenlaufwerk gefunden!\n")
  return
end

-- Sucht Ziel-Diskette (Komponente 'filesystem', die nicht die Boot-Festplatte ist)
local diskProxy = nil
local bootAddress = computer.getBootAddress()

for address in component.list("filesystem") do
  if address ~= bootAddress then
    diskProxy = component.proxy(address)
    break
  end
end

if not diskProxy then
  io.stderr:write("Fehler: Keine beschreibbare Diskette gefunden! Bitte legen Sie eine Diskette ein.\n")
  return
end

local function dateiSchreiben(proxy, dateiname, inhalt)
  local handle = proxy.open(dateiname, "w")
  if handle then
    proxy.write(handle, inhalt)
    proxy.close(handle)
    return true
  end
  return false
end

term.clear()
print("==================================================")
print("     OPENCOMPUTERS DISK MAKER / FLASHER v1.0     ")
print("==================================================")
print("Ziel-Diskette: " .. diskProxy.address:sub(1, 8) .. "...")
print("\nWelche Rolle soll auf die Diskette geschrieben werden?\n")
print("  [1] Server-Diskette")
print("  [2] Reaktor-Client Diskette")
print("  [3] Remote / DHD-Terminal Diskette")
print("  [4] Universelle Diskette (Automatische Rollenerkennung)")
print("  [5] Abbrechen")
print("==================================================")
io.write("Auswahl (1-5): ")

local auswahl = io.read()

if auswahl == "1" then
  diskProxy.setLabel("SERVER_DISK")
  
  local autorunCode = [[
os.execute("server.lua")
]]
  dateiSchreiben(diskProxy, "autorun.lua", autorunCode)
  
  if fs.exists("server.lua") then
    shell.execute("cp server.lua " .. diskProxy.address:sub(1, 3))
  end
  print("\n[OK] Diskette erfolgreich als SERVER konfiguriert!")

elseif auswahl == "2" then
  diskProxy.setLabel("CLIENT_DISK")
  
  local autorunCode = [[
os.execute("client.lua")
]]
  dateiSchreiben(diskProxy, "autorun.lua", autorunCode)
  
  if fs.exists("client.lua") then
    shell.execute("cp client.lua " .. diskProxy.address:sub(1, 3))
  end
  print("\n[OK] Diskette erfolgreich als REAKTOR-CLIENT konfiguriert!")

elseif auswahl == "3" then
  diskProxy.setLabel("REMOTE_DISK")
  
  local autorunCode = [[
os.execute("remote.lua")
]]
  dateiSchreiben(diskProxy, "autorun.lua", autorunCode)
  
  if fs.exists("remote.lua") then
    shell.execute("cp remote.lua " .. diskProxy.address:sub(1, 3))
  end
  print("\n[OK] Diskette erfolgreich als REMOTE / DHD TERMINAL konfiguriert!")

elseif auswahl == "4" then
  diskProxy.setLabel("UNIVERSAL_DISK")
  
  local autorunCode = [[
local component = require("component")
if component.isAvailable("br_reactor") then
  os.execute("client.lua")
elseif component.isAvailable("stargate") then
  os.execute("remote.lua")
else
  os.execute("server.lua")
end
]]
  dateiSchreiben(diskProxy, "autorun.lua", autorunCode)
  
  if fs.exists("server.lua") then shell.execute("cp server.lua " .. diskProxy.address:sub(1, 3)) end
  if fs.exists("client.lua") then shell.execute("cp client.lua " .. diskProxy.address:sub(1, 3)) end
  if fs.exists("remote.lua") then shell.execute("cp remote.lua " .. diskProxy.address:sub(1, 3)) end
  
  print("\n[OK] Diskette erfolgreich als UNIVERSELL konfiguriert!")

else
  print("\nVorgang abgebrochen.")
end
