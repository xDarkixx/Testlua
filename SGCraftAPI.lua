-- Testlua SGCraft API
-- OpenComputers 1.7.10 / SGCraft 1.13.3
-- Local API. No dependency on lua2/sgcraft2.

local component=require("component")
local API={}
local unpackFn=table.unpack or unpack

local function invoke(address,name,...)
 if not address or address=="" then return false,nil,"NO STARGATE INTERFACE ADDRESS" end
 if type(component.invoke)~="function" then return false,nil,"component.invoke unavailable" end
 local args={...}
 local ok,a,b,c=pcall(function()
  return component.invoke(address,name,unpackFn(args,1,#args))
 end)
 -- A successful OpenComputers component call is successful even when the
 -- component method returns nil. This is important for disconnect/openIris/closeIris.
 if ok then return true,a,b,c end
 return false,nil,tostring(a or ("API CALL FAILED: "..tostring(name)))
end

local function cleanAddress(value)
 return tostring(value or ""):gsub("[^0-9A-Za-z]",""):upper()
end

function API.normalizeAddress(value)
 local address=cleanAddress(value)
 if #address~=7 and #address~=9 then return nil,"ADDRESS MUST HAVE 7 OR 9 SYMBOLS" end
 return address
end

function API.formatAddress(value)
 local address=cleanAddress(value)
 if #address==7 then return address:sub(1,4).."-"..address:sub(5,7) end
 if #address==9 then return address:sub(1,4).."-"..address:sub(5,7).."-"..address:sub(8,9) end
 return address
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

local function makeGate(address,primary)
 local okProxy,proxy=pcall(component.proxy,address)
 return {address=address,proxy=okProxy and proxy or nil,methods=API.methods(address),primary=primary==true}
end

function API.find()
 local okPrimary,p=pcall(component.getPrimary,"stargate")
 if okPrimary and p then
  local address=p.address or p
  return makeGate(address,true)
 end
 local okList,found=pcall(function()
  for address in component.list("stargate") do return makeGate(address,false) end
 end)
 if okList and found then return found end
 return nil,"NO STARGATE INTERFACE FOUND"
end

function API.list()
 local result={}
 local primary=nil
 local ok,p=pcall(component.getPrimary,"stargate")
 if ok and p then primary=p.address or p end
 local okList=pcall(function()
  for address in component.list("stargate") do
   local gate=makeGate(address,address==primary)
   result[#result+1]=gate
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
  local pok,pa,pb,pc=pcall(function() return gate.proxy[name](unpackFn(args,1,#args)) end)
  -- Proxy calls can also legitimately return nil.
  if pok then return true,pa,pb,pc end
  return false,nil,tostring(pa)
 end
 return false,nil,tostring(b or a or ("METHOD NOT AVAILABLE: "..name))
end

function API.dial(gate,address)
 local normalized,err=API.normalizeAddress(address)
 if not normalized then return false,nil,err end
 return API.call(gate,"dial",normalized)
end

function API.disconnect(gate) return API.call(gate,"disconnect") end

local function irisCall(gate,preferred,fallback)
 local methods=gate and gate.methods or API.methods(gate and gate.address)
 if methods[preferred] then return API.call(gate,preferred) end
 if methods[fallback] then return API.call(gate,fallback) end
 -- Some SGCraft builds expose the method through the proxy even when
 -- component.methods does not report it, so try both names.
 local ok,a,b=API.call(gate,preferred)
 if ok then return true,a,b end
 return API.call(gate,fallback)
end

function API.openIris(gate) return irisCall(gate,"openIris","irisOpen") end
function API.closeIris(gate) return irisCall(gate,"closeIris","irisClose") end

function API.read(gate)
 if not gate then
  return {present=false,state="Offline",engaged=0,direction="",localAddress="",remoteAddress="",energy=0,iris="Unknown",ok=false,localOK=false,remoteOK=false,energyOK=false,irisOK=false,error="NO STARGATE INTERFACE"}
 end
 local okState,state,engaged,direction=API.call(gate,"stargateState")
 local okLocal,localAddress,localErr=API.call(gate,"localAddress")
 local okRemote,remoteAddress,remoteErr=API.call(gate,"remoteAddress")
 local okEnergy,energy,energyErr=API.call(gate,"energyAvailable")
 local okIris,iris,irisErr=API.call(gate,"irisState")
 local errors={}
 if not okState then errors[#errors+1]="stargateState: "..tostring(state) end
 if not okLocal then errors[#errors+1]="localAddress: "..tostring(localErr) end
 if not okRemote then errors[#errors+1]="remoteAddress: "..tostring(remoteErr) end
 if not okEnergy then errors[#errors+1]="energyAvailable: "..tostring(energyErr) end
 if not okIris then errors[#errors+1]="irisState: "..tostring(irisErr) end
 return {present=true,state=okState and tostring(state or "Unknown") or "API ERROR",engaged=okState and (tonumber(engaged) or 0) or 0,direction=okState and tostring(direction or "") or "",localAddress=okLocal and tostring(localAddress or "") or "",remoteAddress=okRemote and tostring(remoteAddress or "") or "",energy=okEnergy and (tonumber(energy) or 0) or 0,iris=okIris and tostring(iris or "Unknown") or "API ERROR",ok=okState,localOK=okLocal,remoteOK=okRemote,energyOK=okEnergy,irisOK=okIris,error=table.concat(errors," | "),localError=tostring(localErr or ""),remoteError=tostring(remoteErr or ""),energyError=tostring(energyErr or ""),irisError=tostring(irisErr or ""),methods=gate.methods or {}}
end

function API.energyToDial(gate,address)
 local normalized,err=API.normalizeAddress(address)
 if not normalized then return false,nil,err end
 return API.call(gate,"energyToDial",normalized)
end

function API.sendMessage(gate,message) return API.call(gate,"sendMessage",message) end

return API
