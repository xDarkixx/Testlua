-- Testlua Auto Installer
-- Run this file from a Testlua backup floppy.
-- Installs into the current OpenComputers home/working directory.

local component = require("component")
local serialization = require("serialization")
local shell = require("shell")
local fs = require("filesystem")

local LABELS = {
  ["TESTLUA-REACTOR"] = "REACTOR",
  ["TESTLUA-STARGATE"] = "STARGATE",
  ["TESTLUA-SERVER"] = "SERVER",
  ["TESTLUA-CLIENT"] = "CLIENT",
  ["TESTLUA-SYSTEM"] = "SYSTEM"
}

local function writable(proxy)
  return proxy and proxy.isReadOnly and not proxy.isReadOnly()
end

local function findBackupDisk()
  for address in component.list("filesystem") do
    local p = component.proxy(address)
    if writable(p) and p.getLabel then
      local label = pcall(p.getLabel) and p.getLabel() or ""
      if LABELS[label] then return p, label end
    end
  end
  return nil
end

local function readFile(disk, path)
  local h = disk.open(path, "r")
  if not h then return nil end
  local out = {}
  while true do
    local ok, chunk = pcall(disk.read, h, 4096)
    if not ok or not chunk or chunk == "" then break end
    out[#out + 1] = chunk
  end
  pcall(disk.close, h)
  return table.concat(out)
end

local function writeLocal(path, data)
  local parent = fs.path(path)
  if parent and parent ~= "/" and not fs.exists(parent) then
    fs.makeDirectory(parent)
  end
  local f, err = io.open(path, "w")
  if not f then return false, err end
  local ok, msg = pcall(function() f:write(data); f:close() end)
  if not ok then pcall(f.close, f); return false, msg end
  return true
end

local disk, label = findBackupDisk()
if not disk then
  io.stderr:write("Keine Testlua-Backup-Floppy gefunden.\n")
  return
end

local manifestRaw = readFile(disk, "/testlua/manifest.dat")
if not manifestRaw then
  io.stderr:write("Auf der Floppy fehlt /testlua/manifest.dat.\n")
  return
end

local ok, manifest = pcall(serialization.unserialize, manifestRaw)
if not ok or type(manifest) ~= "table" then
  io.stderr:write("Das Backup-Manifest ist beschädigt oder ungültig.\n")
  return
end

local expectedRole = LABELS[label]
if manifest.role and manifest.role ~= expectedRole then
  io.stderr:write("Falsche Backup-Floppy für dieses Manifest.\n")
  return
end

local targetDir = shell.getWorkingDirectory() or "/"
local installed, failed = 0, 0

for name in pairs(manifest.files or {}) do
  if type(name) == "string" and name ~= "" and not name:find("%.%.", 1, true) and not name:find("[/\\]", 1) then
    local data = readFile(disk, "/testlua/" .. name)
    if data then
      local good = writeLocal(fs.concat(targetDir, name), data)
      if good then installed = installed + 1 else failed = failed + 1 end
    else
      failed = failed + 1
    end
  end
end

print("========================================")
print(" TESTLUA AUTO INSTALLER")
print(" System : " .. tostring(expectedRole))
print(" Floppy : " .. tostring(label))
print(" Ziel   : " .. tostring(targetDir))
print(" Installiert: " .. tostring(installed))
print(" Fehler     : " .. tostring(failed))
print("========================================")
if failed == 0 then
  print("Installation erfolgreich.")
else
  print("Installation abgeschlossen, aber nicht alle Dateien konnten installiert werden.")
end
