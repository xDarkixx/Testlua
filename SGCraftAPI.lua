-- Testlua SGCraft API
-- OpenComputers 1.7.10 / SGCraft 1.13.x
-- Standalone API helper kept inside the Testlua repository.
-- Can be required by other Testlua programs, but server.lua also contains
-- the same backend logic so no external repository is required.

local component=require("component")
local API={}

local function invoke(address,name,...)
 if not address or address=="" then return false,nil,"no interface address" end
 if type(component.invoke)~="function" then return false,nil,"component.invoke unavailable" end
 local args={...}
 local ok,a,b,c=pcall(function() return component.invoke(address,name,unpack(args)) end)
 if ok and a~=nil then return true,a,b,c end
 if not ok then return false,nil,tostring(a) end
 return false,nil,tostring(b or ("API call failed: "..tostring(name)))
end

function API.methods(address)
 local result={}
 local ok,m=pcall(component.methods,address)
 if ok and type(m)=="table" then
  for name,value in pairs(m) do if value then result[name]=true end end
 end
 return result
end

function API.list()
 local result={};local primary=nil
 local ok,p=pcall(component.getPrimary,"stargate")
 if ok and p then primary=p.address or p end
 local okList=pcall(function()
  for address in component.list("stargate") do
   local okProxy,proxy=pcall(component.proxy,address)
   result[#result+1]={address=address,proxy=okProxy and proxy or nil,primary=address==primary,methods=API.methods(address)}
  end
 end)
 if not okList then return {} end
 table.sort(result,function(a,b) return a.address<b.address end)
 return result
end

function API.call(gate,name,...)
 if not gate then return false,nil,"no interface" end
 local ok,a,b,c=invoke(gate.address,name,...)
 if ok then return true,a,b,c end
 if gate.proxy and type(gate.proxy[name])=="function" then
  local args={...}
  local pok,pa,pb,pc=pcall(function() return gate.proxy[name](unpack(args)) end)
  if pok and pa~=nil then return true,pa,pb,pc end
  if not pok then return false,nil,tostring(pa) end
 end
 return false,nil,tostring(b or a or "API call failed: "..name)
end

function API.dial(gate,address) return API.call(gate,"dial",address) end
function API.disconnect(gate) return API.call(gate,"disconnect") end

function API.openIris(gate)
 local methods=gate and gate.methods or API.methods(gate and gate.address)
 if methods.openIris then return API.call(gate,"openIris") end
 if methods.irisOpen then return API.call(gate,"irisOpen") end
 return false,nil,"IRIS OPEN METHOD NOT AVAILABLE"
end

function API.closeIris(gate)
 local methods=gate and gate.methods or API.methods(gate and gate.address)
 if methods.closeIris then return API.call(gate,"closeIris") end
 if methods.irisClose then return API.call(gate,"irisClose") end
 return false,nil,"IRIS CLOSE METHOD NOT AVAILABLE"
end

function API.read(gate)
 if not gate then return {state="Offline",engaged=0,direction="",localAddress="",remoteAddress="",energy=0,iris="Unknown",ok=false,irisOK=false} end
 local okState,state,engaged,direction=API.call(gate,"stargateState")
 local okLocal,localAddress=API.call(gate,"localAddress")
 local okRemote,remoteAddress=API.call(gate,"remoteAddress")
 local okEnergy,energy=API.call(gate,"energyAvailable")
 local okIris,iris=API.call(gate,"irisState")
 return {
  state=okState and tostring(state or "Unknown") or "API ERROR",
  engaged=tonumber(engaged) or 0,
  direction=tostring(direction or ""),
  localAddress=okLocal and tostring(localAddress or "") or "",
  remoteAddress=okRemote and tostring(remoteAddress or "") or "",
  energy=tonumber(energy) or 0,
  iris=okIris and tostring(iris or "Unknown") or "API ERROR",
  ok=okState,localOK=okLocal,remoteOK=okRemote,energyOK=okEnergy,irisOK=okIris
 }
end

return API
