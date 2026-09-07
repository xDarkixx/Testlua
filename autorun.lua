-- Automatische Rollenerkennung fuer OpenComputers 1.7.10
local component = require("component")

local function starten(datei)
  local ok, err = pcall(os.execute, datei)
  if not ok then
    io.stderr:write("Fehler beim Starten von " .. datei .. ": " .. tostring(err) .. "\n")
  end
end

-- Reaktor-Computer hat Vorrang.
if component.isAvailable("br_reactor") then
  starten("client.lua")
-- Ein DHD/Remote-Terminal hat Stargate + GPU.
elseif component.isAvailable("stargate") and component.isAvailable("gpu") then
  starten("remote.lua")
-- Ein Server kann ebenfalls eine Stargate-Komponente besitzen; ohne GPU wird er Server.
elseif component.isAvailable("modem") then
  starten("server.lua")
elseif component.isAvailable("br_turbine") then
  starten("client.lua")
else
  io.stderr:write("Keine passende SGC-/Reaktor-Hardware erkannt.\n")
end
