local skynet 	= require "skynet"
local util 		= require "bw.util"
return function(args, data)
    return skynet.call("cms", "lua", "req_login", data.account, data.password)
end
