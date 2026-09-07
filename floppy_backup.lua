-- Testlua Floppy Backup Manager
-- OpenComputers 1.7.10
-- Eine eigene Floppy pro System:
-- TESTLUA-REACTOR, TESTLUA-STARGATE, TESTLUA-SERVER, TESTLUA-CLIENT

local component = require("component")
local serialization = require("serialization")
local fs = require("filesystem")
local shell = require("shell")

local currentDir = shell.getWorkingDirectory() or "/"
local ROLE_LABELS = {
  REACTOR = "TESTLUA-REACTOR",
  STARGATE = "TESTLUA-STARGATE",
  SERVER = "TESTLUA-SERVER",
  CLIENT = "TESTLUA-CLIENT",
  SYSTEM = "TESTLUA-SYSTEM"
}

local function has(name)
  return component.isAvailable(name)
end

local function detectRole()
  if has("br_reactor") then return "REACTOR" end
  if has("stargate") then return "STARGATE" end
  if has("modem") then return "SERVER" end
  return "SYSTEM"
end

local ROLE = detectRole()
local LABEL = ROLE_LABELS[ROLE]

local function isWritable(proxy)
  return proxy and proxy.isReadOnly and not proxy.isReadOnly()
end

-- Niemals automatisch die normale Festplatte nehmen.
-- Eine bereits passend beschriftete Floppy wird bevorzugt.
local function findDisk()
  if not component.isAvailable("filesystem") then return nil end

  local primary = component.getPrimary("filesystem")
  local list = component.list("filesystem")

  -- 1. Explizit passend beschriftete Floppy suchen.
  for address in list do
    if not primary or address ~= primary.address then
      local proxy = component.proxy(address)
      if isWritable(proxy) then
        local label = proxy.getLabel and proxy.getLabel() or ""
        if label == LABEL then return proxy end
      end
    end
  end

  -- 2. Unbeschriftete kleine Wechselmedien erkennen.
  -- Die primäre Festplatte wird grundsätzlich ausgeschlossen.
  for address in component.list("filesystem") do
    if not primary or address ~= primary.address then
      local proxy = component.proxy(address)
      if isWritable(proxy) then
        local label = proxy.getLabel and proxy.getLabel() or ""
        local total = proxy.spaceTotal and proxy.spaceTotal() or 0
        if label == "" and total > 0 and total <= 2000000 then
          if proxy.setLabel then pcall(proxy.setLabel, LABEL) end
          return proxy
        end
      end
    end
  end

  return nil
end

local function readLocal(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local data = f:read("*all") or ""
  f:close()
  return data
end

local function readDisk(proxy, path)
  local f = proxy.open(path, "r")
  if not f then return nil end
  local chunks = {}
  while true do
    local chunk = proxy.read(f, 4096)
    if not chunk or chunk == "" then break end
    chunks[#chunks + 1] = chunk
  end
  pcall(proxy.close, f)
  return table.concat(chunks)
end

local function writeDisk(proxy, path, data)
  local parent = fs.path(path)
  if parent and parent ~= "/" and not proxy.exists(parent) then
    pcall(proxy.makeDirectory, parent)
  end
  local f = proxy.open(path, "w")
  if not f then return false end
  local ok = true
  local pos = 1
  while pos <= #data do
    local chunk = data:sub(pos, pos + 4095)
    local wrote = pcall(proxy.write, f, chunk)
    if not wrote then ok = false; break end
    pos = pos + #chunk
  end
  pcall(proxy.close, f)
  return ok
end

local function getBackupFiles()
  local files = {}
  local entries = fs.list(currentDir)
  for name in entries do
    if name ~= "floppy_backup.lua" and (name:sub(-4) == ".lua" or name:sub(-4) == ".dat") then
      files[#files + 1] = name
    end
  end
  table.sort(files)
  return files
end

local function backup()
  local disk = findDisk()
  if not disk then
    return false, "Keine passende Floppy gefunden. Bitte eine eigene Floppy einlegen."
  end

  if disk.setLabel then pcall(disk.setLabel, LABEL) end
  if not disk.exists("/testlua") then pcall(disk.makeDirectory, "/testlua") end

  local manifest = {
    version = 2,
    role = ROLE,
    label = LABEL,
    files = {},
    created = os.time and os.time() or 0
  }

  local used = 0
  for _, name in ipairs(getBackupFiles()) do
    local data = readLocal(fs.concat(currentDir, name))
    if data then
      local target = fs.concat("/testlua", name)
      local ok = writeDisk(disk, target, data)
      if ok then
        manifest.files[name] = #data
        used = used + #data
      end
    end
  end

  local raw = serialization.serialize(manifest)
  if not writeDisk(disk, "/testlua/manifest.dat", raw) then
    return false, "Backup konnte nicht vollständig geschrieben werden."
  end

  return true, "Backup " .. ROLE .. " gespeichert auf " .. LABEL .. " (" .. tostring(used) .. " Bytes)."
end

local function restore()
  local disk = findDisk()
  if not disk then
    return false, "Keine passende Floppy für " .. ROLE .. " gefunden."
  end

  local raw = readDisk(disk, "/testlua/manifest.dat")
  if not raw then return false, "Kein Testlua-Backup auf dieser Floppy gefunden." end

  local good, manifest = pcall(serialization.unserialize, raw)
  if not good or type(manifest) ~= "table" then
    return false, "Ungültiges Backup."
  end
  if manifest.label ~= LABEL or manifest.role ~= ROLE then
    return false, "Falsche Floppy: erwartet " .. LABEL .. "."
  end

  for name in pairs(manifest.files or {}) do
    local content = readDisk(disk, fs.concat("/testlua", name))
    if content then
      local wf = io.open(fs.concat(currentDir, name), "w")
      if wf then
        wf:write(content)
        wf:close()
      end
    end
  end

  return true, "Backup " .. ROLE .. " von " .. LABEL .. " wiederhergestellt."
end

local function status()
  local disk = findDisk()
  print("Testlua Floppy Backup")
  print("System: " .. ROLE)
  print("Erwartetes Label: " .. LABEL)
  if disk then
    print("Floppy: OK")
    print("Label: " .. tostring(disk.getLabel and disk.getLabel() or ""))
    if disk.spaceTotal then
      print("Platz: " .. tostring(disk.spaceUsed()) .. " / " .. tostring(disk.spaceTotal()))
    end
  else
    print("Floppy: NICHT GEFUNDEN")
  end
end

local args = shell.parse(...)
local cmd = tostring(args[1] or "backup")

if cmd == "restore" then
  local ok, msg = restore()
  print(msg)
elseif cmd == "status" then
  status()
else
  local ok, msg = backup()
  print(msg)
end
