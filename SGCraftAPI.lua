-- Testlua SGCraft API
-- OpenComputers 1.7.10 / SGCraft 1.13.3
-- Standalone local API. No dependency on lua2/sgcraft2.

local component=require("component")
local API={}
local unpackFn=table.unpack or unpack

local function safeAvailable()
 local ok,v=pcall(component.isAvailable,"stargate")
 return ok and v==true
end

local function invoke(address,name,...)
 if not address or address=="" then return false,nil,"NO STARGATE INTERFACE ADDRESS" end
 if type(component.invoke)~="function" then return false,nil,"COMPONENT.INVOKE UNAVAILABLE" end
 local argc=select("#",...)
 local ok,a,b,c
 if argc==0 then
  ok,a,b,c=pcall(component.invoke,address,name)
 elseif argc==1 then
  ok,a,b,c=pcall(component.invoke,address,name,...)
 elseif argc==2 then
  ok,a,b,c=pcall(component.invoke,address,name,...)
 else
  local args={...}
  ok,a,b,c=pcall(function() return component.invoke(address,name,unpackFn(args,1,#args)) end)
 end
 -- IMPORTANT: SGCraft command methods can successfully return nil.
 if ok then return true,a,b,c end
 return false,nil,tostring(a or ("API CALL FAILED: "..tostring(name)))
end

local function proxyInvoke(proxy,name,...)
 if not proxy or type(proxy[name])~="function" then return false,nil,"METHOD NOT AVAILABLE: "..tostring(name) end
 local ok,a,b,c=pcall(proxy[name],...)
 -- A successful command may return nil.
 if ok then return true,a,b,c end
 return false,nil,tostring(a or ("PROXY CALL FAILED: "..tostring(name)))
end

local function cleanAddress(value)
 return tostring(value or ""):gsub("[^0-9A-Za-z]",""):upper()
end

function API.normalizeAddress(value)
 local a=cleanAddress(value)
 if #a~=7 and #a~=9 then return nil,"ADDRESS MUST HAVE 7 OR 9 SYMBOLS" end
 return a
end

function API.formatAddress(value)
 local a=cleanAddress(value)
 if #a==7 then return a:sub(1,4).."-"..a:sub(5,7) end
 if #a==9 then return a:sub(1,4).."-"..a:sub(5,7).."-"..a:sub(8,9) end
 return a
end

local function methodMap(address)
 local result={}
 if not address or type(component.methods)~="function" then return result end
 local ok,m=pcall(component.methods,address)
 if ok and type(m)=="table" then
  for name,value in pairs(m) do if value then result[name]=true end end
 end
 return result
end

local function makeGate(address,primary)
 local okProxy,proxy=pcall(component.proxy,address)
 if not okProxy then proxy=nil end
 return {address=address,proxy=proxy,primary=primary==true,methods=methodMap(address)}
end

function API.find()
 local okPrimary,p=pcall(component.getPrimary,"stargate")
 if okPrimary and p then
  local address=p.address or p
  if address then return makeGate(address,true) end
 end
 local okList,found=pcall(function()
  if type(component.list)~="function" then return nil end
  for address in component.list("stargate") do
   return makeGate(address,false)
  end
 end)
 if okList and found then return found end
 if not safeAvailable() then return nil,"STARGATE COMPONENT NOT AVAILABLE" end
 return nil,"NO STARGATE INTERFACE FOUND"
end

function API.list()
 local result={}
 local primary=nil
 local ok,p=pcall(component.getPrimary,"stargate")
 if ok and p then primary=p.address or p end
 local okList=pcall(function()
  if type(component.list)~="function" then return end
  for address in component.list("stargate") do
   result[#result+1]=makeGate(address,address==primary)
  end
 end)
 if not okList then return {} end
 table.sort(result,function(a,b) return tostring(a.address)<tostring(b.address) end)
 return result
end

function API.invoke(gate,name,...)
 if not gate or not gate.address then return false,nil,"NO STARGATE INTERFACE" end
 local ok,a,b,c=invoke(gate.address,name,...)
 if ok then return true,a,b,c end
 local pok,pa,pb,pc=proxyInvoke(gate.proxy,name,...)
 if pok then return true,pa,pb,pc end
 return false,nil,tostring(b or a or pb or ("API CALL FAILED: "..tostring(name)))
end

function API.call(gate,name,...)
 return API.invoke(gate,name,...)
end

function API.dial(gate,address)
 local a,err=API.normalizeAddress(address)
 if not a then return false,nil,err end
 return API.invoke(gate,"dial",a)
end

function API.disconnect(gate)
 return API.invoke(gate,"disconnect")
end

local function irisCall(gate,preferred,fallback)
 if gate and gate.methods then
  if gate.methods[preferred] then return API.invoke(gate,preferred) end
  if gate.methods[fallback] then return API.invoke(gate,fallback) end
 end
 local ok,a,b=API.invoke(gate,preferred)
 if ok then return true,a,b end
 return API.invoke(gate,fallback)
end

function API.openIris(gate) return irisCall(gate,"openIris","irisOpen") end
function API.closeIris(gate) return irisCall(gate,"closeIris","irisClose") end
function API.sendMessage(gate,message) return API.invoke(gate,"sendMessage",message) end
function API.energyToDial(gate,address)
 local a,err=API.normalizeAddress(address)
 if not a then return false,nil,err end
 return API.invoke(gate,"energyToDial",a)
end

function API.read(gate)
 if not gate then
  return {present=false,state="NO INTERFACE",engaged=0,direction="",localAddress="",remoteAddress="",energy=0,iris="Unknown",ok=false,error="NO SGCraft INTERFACE DETECTED",localOK=false,remoteOK=false,energyOK=false,irisOK=false,methods={}}
 end
 local okState,state,engaged,direction=API.invoke(gate,"stargateState")
 local okLocal,localAddress,localErr=API.invoke(gate,"localAddress")
 local okRemote,remoteAddress,remoteErr=API.invoke(gate,"remoteAddress")
 local okEnergy,energy,energyErr=API.invoke(gate,"energyAvailable")
 local okIris,iris,irisErr=API.invoke(gate,"irisState")
 local errors={}
 if not okState then errors[#errors+1]="stargateState: "..tostring(state) end
 if not okLocal then errors[#errors+1]="localAddress: "..tostring(localErr) end
 if not okRemote then errors[#errors+1]="remoteAddress: "..tostring(remoteErr) end
 if not okEnergy then errors[#errors+1]="energyAvailable: "..tostring(energyErr) end
 if not okIris then errors[#errors+1]="irisState: "..tostring(irisErr) end
 return {present=true,state=okState and tostring(state or "Unknown") or "API ERROR",engaged=okState and (tonumber(engaged) or 0) or 0,direction=okState and tostring(direction or "") or "",localAddress=okLocal and tostring(localAddress or "") or "",remoteAddress=okRemote and tostring(remoteAddress or "") or "",energy=okEnergy and (tonumber(energy) or 0) or 0,iris=okIris and tostring(iris or "Unknown") or "API ERROR",ok=okState,localOK=okLocal,remoteOK=okRemote,energyOK=okEnergy,irisOK=okIris,error=table.concat(errors," | "),localError=tostring(localErr or ""),remoteError=tostring(remoteErr or ""),energyError=tostring(energyErr or ""),irisError=tostring(irisErr or ""),methods=gate.methods or {}}
end

return API
