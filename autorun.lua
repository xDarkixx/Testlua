-- Automatische Rollenerkennung fuer OpenComputers 1.7.10
-- Das vorhandene Design der Programme wird nicht veraendert.
local component = require("component")

local function starten(datei)
  local ok = pcall(os.execute, datei)
  if not ok then
    io.stderr:write("Fehler beim Starten von " .. datei .. "\n")
  end
end

if component.isAvailable("br_reactor") then
  starten("client.lua")
elseif component.isAvailable("stargate") then
  starten("remote.lua")
elseif component.isAvailable("br_turbine") then
  starten("client.lua")
elseif component.isAvailable("modem") then
  starten("server.lua")
else
  io.stderr:write("Keine passende SGC-/Reaktor-Hardware erkannt.\n")
end
