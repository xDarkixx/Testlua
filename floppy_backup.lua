-- Testlua Floppy Backup Manager
-- OpenComputers 1.7.10
-- Sichert alle wichtigen Testlua-Daten gemeinsam auf eine Floppy.

local component = require("component")
local serialization = require("serialization")
local fs = require("filesystem")
local shell = require("shell")

local currentDir = shell.getWorkingDirectory() or "/"
local LABEL = "TESTLUA-BACKUP"
local DEFAULT_FILES = {
  "reactor_config.dat",
  "sgc_adressbuch.dat"
}

local function findDisk()
  if not component.isAvailable("filesystem") then return nil end
  local primary = component.getPrimary("filesystem")
  if primary and primary.isReadOnly and not primary.isReadOnly() then
    local label = primary.getLabel and primary.getLabel() or ""
    if label == LABEL then return primary end
  end
  local list = component.list("filesystem")
  for address in list do
    local proxy = component.proxy(address)
    if proxy and proxy.isReadOnly and not proxy.isReadOnly() then
      return proxy
    end
  end
  return nil
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local data = f:read("*all") or ""
  f:close()
  return data
end

local function writeFile(proxy, path, data)
  local f = proxy.open(path, "w")
  if not f then return false end
  local ok = pcall(function() proxy.write(f, data) end)
  pcall(proxy.close, f)
  return ok
end

local function backup()
  local disk = findDisk()
  if not disk then return false, "Keine beschreibbare Floppy gefunden." end

  if disk.setLabel then pcall(disk.setLabel, LABEL) end
  if not disk.exists("/testlua") then pcall(disk.makeDirectory, "/testlua") end

  local manifest = {
    version = 1,
    label = LABEL,
    files = {}
  }

  for _, name in ipairs(DEFAULT_FILES) do
    local data = readFile(fs.concat(currentDir, name))
    if data then
      if writeFile(disk, fs.concat("/testlua", name), data) then
        manifest.files[name] = true
      end
    end
  end

  local data = serialization.serialize(manifest)
  if not writeFile(disk, "/testlua/manifest.dat", data) then
    return false, "Manifest konnte nicht geschrieben werden." 
  end

  return true, "Backup auf " .. LABEL .. " gespeichert."
end

local function restore()
  local disk = findDisk()
  if not disk or not disk.exists("/testlua/manifest.dat") then
    return false, "Kein Testlua-Backup auf der Floppy gefunden."
  end

  local f = disk.open("/testlua/manifest.dat", "r")
  if not f then return false, "Manifest nicht lesbar." end
  local raw = ""
  local ok = pcall(function() raw = disk.read(f, math.huge) or "" end)
  pcall(disk.close, f)
  if not ok then return false, "Manifest konnte nicht gelesen werden." end

  local good, manifest = pcall(serialization.unserialize, raw)
  if not good or type(manifest) ~= "table" then
    return false, "Ungültiges Backup." 
  end

  for name in pairs(manifest.files or {}) do
    local rf = disk.open(fs.concat("/testlua", name), "r")
    if rf then
      local content = disk.read(rf, math.huge) or ""
      pcall(disk.close, rf)
      local wf = io.open(fs.concat(currentDir, name), "w")
      if wf then wf:write(content); wf:close() end
    end
  end

  return true, "Backup von " .. LABEL .. " wiederhergestellt."
end

local cmd = tostring((shell.parse(...))[1] or "")
if cmd == "restore" then
  local ok, msg = restore()
  print(msg)
  return
end

local ok, msg = backup()
print(msg)
