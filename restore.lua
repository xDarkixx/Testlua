local component = require("component")
local fs = require("filesystem")
local shell = require("shell")
local serialization = require("serialization")
local computer = require("computer") -- 'computer' Modul hinzugefügt

local currentDir = shell.getWorkingDirectory() or "/"
local ZIEL_CONFIG = fs.concat(currentDir, "reactor_config.dat")
local ZIEL_SERVER = fs.concat(currentDir, "server.lua")

print("=== REAKTOR- & SGC-WIEDERHERSTELLUNG ===")

local diskProxy = nil
for address in component.list("filesystem") do
  if address ~= computer.getBootAddress() then 
    diskProxy = component.proxy(address) 
    break 
  end
end

if not diskProxy then 
  io.stderr:write("Fehler: Keine Backup-Diskette gefunden!\n") 
  return 
end

-- Liest Daten direkt über den Proxy-Stream, um 'File not found' durch falsche Pfad-Labels zu vermeiden
local function restoreFileFromProxy(srcName, destPath)
  if diskProxy.exists(srcName) then
    local fIn = diskProxy.open(srcName, "r")
    local fOut = io.open(destPath, "w")
    if fIn and fOut then
      local chunk = diskProxy.read(fIn, 2048)
      while chunk do
        fOut:write(chunk)
        chunk = diskProxy.read(fIn, 2048)
      end
      diskProxy.close(fIn)
      fOut:close()
      return true
    end
  end
  return false
end

if restoreFileFromProxy("reactor_backup.dat", ZIEL_CONFIG) then
  print("[OK] System-Konfiguration eingespielt.")
else
  print("[Warnung] Keine Konfigurationsdatei gefunden.")
end

if restoreFileFromProxy("server_backup.lua", ZIEL_SERVER) then
  print("[OK] server.lua erfolgreich wiederhergestellt.")
end

print("\nSystem-Restore abgeschlossen! Tippe 'server' zum Starten.")
