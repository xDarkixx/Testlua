-- Testlua SGCraft API
-- OpenComputers 1.7.10 / SGCraft 1.13.x
-- Local API: no dependency on lua2/sgcraft2.

local component=require("component")
local API={}
local unpackFn=table.unpack or unpack

local function invoke(address,name,...)
 if not address or address=="" then return false,nil,"NO STARGATE INTERFACE ADDRESS" end
 if type(component.invoke)~="function" then return false,nil,"component.invoke unavailable" end
 local args={...}
 local ok,a,b,c=pcall(function() return component.invoke(address,name,unpackFn(args)) end)
 if ok and a~=nil then return true,a,b,c end
 if not ok then return false,nil,tostring(a) end
 return false,nil,tostring(b or ("API CALL FAILED: "..tostring(name)))
end

function API.methods(address)
 local result={}
 if not address then return result end
 local ok,m=pcall(component.methods,address)
 if ok and type(m)=="table" then
  for name,value in pairs(m) do if value then result[name]=true end end
 end
 return result
end

function API.find()
 if not component.isAvailable("stargate") then return nil,"STARGATE COMPONENT NOT AVAILABLE" end
 local ok,p=pcall(component.getPrimary,"stargate")
 if ok and p then
  local address=p.address or p
  local okProxy,proxy=pcall(component.proxy,address)
  if not okProxy then proxy=nil end
  return {address=address,proxy=proxy,methods=API.methods(address),primary=true}
 end
 local okList=pcall(function()
  for address in component.list("stargate") do
   local okProxy,proxy=pcall(component.proxy,address)
   if okProxy then return {address=address,proxy=proxy,methods=API.methods(address),primary=false} end
  end
 end)
 if okList then
  -- component.list iteration is handled below because return inside pcall is not portable across OC Lua variants.
 end
 for address in component.list("stargate") do
  local okProxy,proxy=pcall(component.proxy,address)
  if okProxy then return {address=address,proxy=proxy,methods=API.methods(address),primary=false} end
 end
 return nil,"NO STARGATE INTERFACE FOUND"
end

function API.list()
 local result={}
 if not component.isAvailable("stargate") then return result end
 local primary=nil
 local ok,p=pcall(component.getPrimary,"stargate")
 if ok and p then primary=p.address or p end
 local okList=pcall(function()
  for address in component.list("stargate") do
   local okProxy,proxy=pcall(component.proxy,address)
   result[#result+1]={address=address,proxy=okProxy and proxy or nil,primary=address==primary,methods=API.methods(address)}
  end
 end)
 if not okList then return {} end
 table.sort(result,function(a,b) return tostring(a.address)<tostring(b.address) end)
 return result
end

function API.call(gate,name,...)
 if not gate or not gate.address then return false,nil,"NO STARGATE INTERFACE" end
 local ok,a,b,c=invoke(gate.address,name,...)
 if ok then return true,a,b,c end
 if gate.proxy and type(gate.proxy[name])=="function" then
  local args={...}
  local pok,pa,pb,pc=pcall(function() return gate.proxy[name](unpackFn(args)) end)
  if pok and pa~=nil then return true,pa,pb,pc end
  if not pok then return false,nil,tostring(pa) end
 end
 return false,nil,tostring(b or a or ("METHOD NOT AVAILABLE: "..name))
end

function API.dial(gate,address)
 address=tostring(address or ""):gsub("[^0-9A-Za-z]",""):upper()
 if #address~=7 and #address~=9 then return false,nil,"ADDRESS MUST HAVE 7 OR 9 SYMBOLS" end
 return API.call(gate,"dial",address)
end

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
 return {state=okState and tostring(state or "Unknown") or "API ERROR",engaged=tonumber(engaged) or 0,direction=tostring(direction or ""),localAddress=okLocal and tostring(localAddress or "") or "",remoteAddress=okRemote and tostring(remoteAddress or "") or "",energy=tonumber(energy) or 0,iris=okIris and tostring(iris or "Unknown") or "API ERROR",ok=okState,localOK=okLocal,remoteOK=okRemote,energyOK=okEnergy,irisOK=okIris}
end

return API
