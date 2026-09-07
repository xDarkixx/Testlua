local component = require("component")
local term = require("term")
local computer = require("computer")

if not component.isAvailable("filesystem") then
  io.stderr:write("Fehler: Kein Dateisystem oder Diskettenlaufwerk gefunden!\n")
  return
end

local diskProxy = nil
local bootAddress = computer.getBootAddress()

for address in component.list("filesystem") do
  if address ~= bootAddress then
    local proxy = component.proxy(address)
    if proxy and proxy.isReadOnly and not proxy.isReadOnly() then
      diskProxy = proxy
      break
    end
  end
end

if not diskProxy then
  io.stderr:write("Fehler: Keine beschreibbare Diskette gefunden!\n")
  return
end

local function dateiLesen(dateiname)
  local f = io.open(dateiname, "r")
  if not f then return nil end
  local content = f:read("*all")
  f:close()
  return content
end

local function dateiSchreiben(proxy, dateiname, inhalt)
  local handle = proxy.open(dateiname, "w")
  if not handle then return false end
  local ok = pcall(function()
    proxy.write(handle, inhalt)
    proxy.close(handle)
  end)
  return ok
end

local function kopiere(proxy, dateiname)
  local content = dateiLesen(dateiname)
  if not content then return false end
  return dateiSchreiben(proxy, dateiname, content)
end

local function autorun(rolle)
  if rolle == "SERVER" then
    return "os.execute(\"server.lua\")\n"
  elseif rolle == "CLIENT" then
    return "os.execute(\"client.lua\")\n"
  elseif rolle == "REMOTE" then
    return "os.execute(\"remote.lua\")\n"
  end

  return [[
local component = require("component")
if component.isAvailable("br_reactor") then
  os.execute("client.lua")
elseif component.isAvailable("stargate") or component.isAvailable("gpu") and component.isAvailable("modem") then
  os.execute("remote.lua")
else
  os.execute("server.lua")
end
]]
end

term.clear()
print("==================================================")
print("     OPENCOMPUTERS DISK MAKER / FLASHER v2.0     ")
print("==================================================")
print("Ziel-Diskette: " .. tostring(diskProxy.address):sub(1, 8) .. "...")
print("\nWelche Rolle soll auf die Diskette geschrieben werden?\n")
print("  [1] Server-Diskette")
print("  [2] Reaktor-Client Diskette")
print("  [3] Remote / DHD-Terminal Diskette")
print("  [4] Universelle Diskette (Automatische Rollenerkennung)")
print("  [5] Abbrechen")
print("==================================================")
io.write("Auswahl (1-5): ")

local auswahl = io.read()
local rolle, label

if auswahl == "1" then
  rolle, label = "SERVER", "SERVER_DISK"
elseif auswahl == "2" then
  rolle, label = "CLIENT", "CLIENT_DISK"
elseif auswahl == "3" then
  rolle, label = "REMOTE", "REMOTE_DISK"
elseif auswahl == "4" then
  rolle, label = "UNIVERSAL", "UNIVERSAL_DISK"
else
  print("\nVorgang abgebrochen.")
  return
end

if diskProxy.setLabel then diskProxy.setLabel(label) end

if not dateiSchreiben(diskProxy, "autorun.lua", autorun(rolle)) then
  io.stderr:write("Fehler: autorun.lua konnte nicht geschrieben werden.\n")
  return
end

local fehler = {}
for _, dateiname in ipairs({"server.lua", "client.lua", "remote.lua"}) do
  if not kopiere(diskProxy, dateiname) then
    table.insert(fehler, dateiname)
  end
end

print("\n[OK] Diskette als " .. label .. " vorbereitet.")
if #fehler > 0 then
  print("[HINWEIS] Nicht gefunden/nicht kopiert: " .. table.concat(fehler, ", "))
end
print("Die vorhandene SGC-/Reaktor-GUI bleibt unverändert.")
