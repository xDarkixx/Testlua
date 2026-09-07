local component = require("component")
local fs = require("filesystem")
local shell = require("shell")
local computer = require("computer")

local currentDir = shell.getWorkingDirectory() or "/"
local ZIEL_CONFIG = fs.concat(currentDir, "reactor_config.dat")
local ZIEL_SERVER = fs.concat(currentDir, "server.lua")

print("=== REAKTOR- & SGC-WIEDERHERSTELLUNG ===")

local diskProxy = nil
for address in component.list("filesystem") do
  if address ~= computer.getBootAddress() then
    local proxy = component.proxy(address)
    if proxy and proxy.exists and proxy.exists("reactor_backup.dat") or proxy and proxy.exists and proxy.exists("server_backup.lua") then
      diskProxy = proxy
      break
    end
  end
end

if not diskProxy then
  io.stderr:write("Fehler: Keine Backup-Diskette gefunden!\n")
  return
end

local function restoreFileFromProxy(srcName, destPath)
  if not diskProxy.exists(srcName) then return false, "nicht vorhanden" end

  local fIn = diskProxy.open(srcName, "r")
  if not fIn then return false, "Quelle konnte nicht geoeffnet werden" end

  local fOut = io.open(destPath, "w")
  if not fOut then
    diskProxy.close(fIn)
    return false, "Zieldatei konnte nicht geoeffnet werden"
  end

  local ok, err = pcall(function()
    while true do
      local chunk = diskProxy.read(fIn, 2048)
      if not chunk or #chunk == 0 then break end
      fOut:write(chunk)
    end
  end)

  diskProxy.close(fIn)
  fOut:close()

  if not ok then
    return false, tostring(err)
  end
  return true
end

local okConfig, errConfig = restoreFileFromProxy("reactor_backup.dat", ZIEL_CONFIG)
if okConfig then
  print("[OK] System-Konfiguration eingespielt.")
else
  print("[Warnung] Konfiguration: " .. tostring(errConfig))
end

local okServer, errServer = restoreFileFromProxy("server_backup.lua", ZIEL_SERVER)
if okServer then
  print("[OK] server.lua erfolgreich wiederhergestellt.")
else
  print("[Hinweis] server.lua: " .. tostring(errServer))
end

print("\nSystem-Restore abgeschlossen!")
