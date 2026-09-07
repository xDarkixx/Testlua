-- Testlua Floppy Backup Manager
-- OpenComputers 1.7.10
-- Eigene Floppy pro System:
-- TESTLUA-REACTOR, TESTLUA-STARGATE, TESTLUA-SERVER, TESTLUA-CLIENT, TESTLUA-SYSTEM

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

local function has(name) return component.isAvailable(name) end

local function detectRole()
  if has("br_reactor") then return "REACTOR" end
  if has("stargate") then return "STARGATE" end
  if has("modem") then return "SERVER" end
  return "SYSTEM"
end

local ROLE = detectRole()
local LABEL = ROLE_LABELS[ROLE]

local function getProxy(address)
  local ok, proxy = pcall(component.proxy, address)
  if ok then return proxy end
  return nil
end

local function isWritable(proxy)
  if not proxy then return false end
  if not proxy.isReadOnly then return true end
  local ok, ro = pcall(proxy.isReadOnly)
  return ok and not ro
end

local function diskSize(proxy)
  if not proxy or not proxy.spaceTotal then return 0 end
  local ok, total = pcall(proxy.spaceTotal)
  return ok and tonumber(total) or 0
end

-- Findet die tatsächlich eingelegte beschreibbare Floppy.
-- Wichtig: Eine Floppy darf auch PRIMARY sein. Nur große normale Festplatten
-- werden ausgeschlossen. Eine passende TESTLUA-Floppy hat immer Vorrang.
local function findDisk()
  if not has("filesystem") then return nil end

  local candidates = {}
  for address in component.list("filesystem") do
    local proxy = getProxy(address)
    if isWritable(proxy) then
      local label = ""
      if proxy.getLabel then
        local ok, value = pcall(proxy.getLabel)
        if ok then label = tostring(value or "") end
      end
      local total = diskSize(proxy)
      candidates[#candidates + 1] = {address=address, proxy=proxy, label=label, total=total}
    end
  end

  -- 1. Bereits korrekt beschriftete Floppy immer bevorzugen.
  for _, c in ipairs(candidates) do
    if c.label == LABEL then return c.proxy end
  end

  -- 2. Kleine Wechselmedien als neue Floppy erkennen.
  -- 2 MB ist absichtlich etwas großzügiger als eine 1.44-MB-Floppy.
  for _, c in ipairs(candidates) do
    if c.label == "" and c.total > 0 and c.total <= 2000000 then
      if c.proxy.setLabel then pcall(c.proxy.setLabel, LABEL) end
      return c.proxy
    end
  end

  -- 3. Falls die Floppy bereits ein anderes Label trägt, aber klein ist,
  --    darf sie für dieses System verwendet und korrekt beschriftet werden.
  for _, c in ipairs(candidates) do
    if c.total > 0 and c.total <= 2000000 then
      if c.proxy.setLabel then pcall(c.proxy.setLabel, LABEL) end
      return c.proxy
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
  local ok, handle = pcall(proxy.open, path, "r")
  if not ok or not handle then return nil end
  local chunks = {}
  while true do
    local okRead, chunk = pcall(proxy.read, handle, 4096)
    if not okRead or not chunk or chunk == "" then break end
    chunks[#chunks + 1] = chunk
  end
  pcall(proxy.close, handle)
  return table.concat(chunks)
end

local function writeDisk(proxy, path, data)
  local parent = fs.path(path)
  if parent and parent ~= "/" and not proxy.exists(parent) then
    pcall(proxy.makeDirectory, parent)
  end

  local okOpen, handle = pcall(proxy.open, path, "w")
  if not okOpen or not handle then return false end

  local ok = true
  local pos = 1
  while pos <= #data do
    local chunk = data:sub(pos, math.min(pos + 4095, #data))
    local okWrite = pcall(proxy.write, handle, chunk)
    if not okWrite then ok = false; break end
    pos = pos + #chunk
  end
  pcall(proxy.close, handle)
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
    return false, "Keine beschreibbare Floppy gefunden. Bitte eine Floppy einlegen."
  end

  if disk.setLabel then pcall(disk.setLabel, LABEL) end
  if not disk.exists("/testlua") then pcall(disk.makeDirectory, "/testlua") end

  local manifest = {
    version = 3,
    role = ROLE,
    label = LABEL,
    files = {},
    created = os.time and os.time() or 0
  }

  local used = 0
  local failed = 0
  for _, name in ipairs(getBackupFiles()) do
    local data = readLocal(fs.concat(currentDir, name))
    if data then
      local target = fs.concat("/testlua", name)
      if writeDisk(disk, target, data) then
        manifest.files[name] = #data
        used = used + #data
      else
        failed = failed + 1
      end
    end
  end

  if not writeDisk(disk, "/testlua/manifest.dat", serialization.serialize(manifest)) then
    return false, "Backup konnte nicht vollständig geschrieben werden (kein Speicherplatz oder Floppy schreibgeschützt)."
  end

  if failed > 0 then
    return false, "Backup teilweise fehlgeschlagen: " .. tostring(failed) .. " Datei(en) konnten nicht geschrieben werden."
  end

  return true, "Backup " .. ROLE .. " gespeichert auf " .. LABEL .. " (" .. tostring(used) .. " Bytes)."
end

local function restore()
  local disk = findDisk()
  if not disk then
    return false, "Keine beschreibbare Floppy für " .. ROLE .. " gefunden."
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

  local restored = 0
  for name in pairs(manifest.files or {}) do
    local content = readDisk(disk, fs.concat("/testlua", name))
    if content then
      local path = fs.concat(currentDir, name)
      local wf = io.open(path, "w")
      if wf then
        wf:write(content)
        wf:close()
        restored = restored + 1
      end
    end
  end

  return true, "Backup " .. ROLE .. " von " .. LABEL .. " wiederhergestellt (" .. tostring(restored) .. " Dateien)."
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
local cmd = tostring(args[1] or "backup"):lower()

if cmd == "restore" then
  local ok, msg = restore()
  print(msg)
  return ok
elseif cmd == "status" then
  status()
  return true
else
  local ok, msg = backup()
  print(msg)
  return ok
end
