local skynet    = require "skynet"
local bewater   = require "bw.bewater"
local log       = require "bw.log"

local trace = log.trace("watchdog")

local server_path, player_path = ...
assert(server_path) -- 服务器逻辑(xxx.xxxserver)
assert(player_path) -- 玩家逻辑(xxx.xxxplayer_t)

local server = require(server_path)

local GATE
local fd2uid = {}
local uid2agent = {}    -- 每个玩家对应的agent
local free_agents = {}  -- 空闲的agent addr -> true
local full_agents = {}  -- 满员的agent addr -> true

local PLAYER_PER_AGENT  -- 每个agent支持player最大值
local PROTO

local function create_agent()
    local agent = skynet.newservice("sock/agent", player_path)
    skynet.call(agent, "lua", "init", GATE, skynet.self(), PLAYER_PER_AGENT, PROTO)
    free_agents[agent] = true
    return agent
end

local SOCKET = {}
function SOCKET.open(fd, addr)
	trace("New client from : " .. addr, fd)
    local agent = next(free_agents)
    if not agent then
        agent = create_agent()
    end
	local is_full = skynet.call(agent, "lua", "new_player", fd, addr)
    if is_full then
        free_agents[agent] = nil
        full_agents[agent] = true
    end
end

local function close_socket(fd)
    trace("close_socket", fd)
    local uid = fd2uid[fd]
    if not uid then
        skynet.error("uid not exist, fd:", fd)
        return
    end
    local agent = uid2agent[uid]
    if not agent then
        skynet.error("agent not exist, uid:", uid)
        return
    end
    skynet.call(agent, "lua", "socket_close", uid, fd)
    skynet.call(GATE, "lua", "kick", fd)
    fd2uid[fd] = nil
end

function SOCKET.close(fd)
	--print("socket close",fd)
    close_socket(fd)
end

function SOCKET.error(fd, msg)
	print("socket error",fd, msg)
    close_socket(fd)
end

function SOCKET.warning(fd, size)
	-- size K bytes havn't send out in fd
	print("socket warning", fd, size)
end

function SOCKET.data(fd, msg)
    print("socket data", fd, msg)
end

local CMD = {}
function CMD.start(conf)
    PLAYER_PER_AGENT = conf.player_per_agent or 100
    PROTO = conf.proto
    server:start()
    conf.preload = conf.preload or 10     -- 预加载agent数量
    skynet.call(GATE, "lua", "open" , conf)
    for i = 1, conf.preload do
        local agent = skynet.newservice("sock/agent", player_path)
        skynet.call(agent, "lua", "init", GATE, skynet.self(), PLAYER_PER_AGENT, PROTO)
        free_agents[agent] = true
    end
end

function CMD.stop()
    for agent, _ in pairs(free_agents) do
        skynet.send(agent, "lua", "stop")
    end
    for agent, _ in pairs(full_agents) do
        skynet.send(agent, "lua", "stop")
    end
    while true do
        local count = 0
        for _, v in pairs(free_agents) do
            count = count + 1
        end
        for _, v in pairs(full_agents) do
            count = count + 1
        end
        skynet.error(string.format("left agent:%d", count))
        if count == 0 then
            return
        end
        skynet.sleep(10)
    end
end

function CMD.set_free(agent)
    free_agents[agent] = true
    full_agents[agent] = nil
end

function CMD.free_agent(agent)
    free_agents[agent] = nil
    full_agents[agent] = nil
end

-- 上线后agent绑定uid，下线缓存一段时间
function CMD.player_online(agent, uid, fd)
    uid2agent[uid] = agent
    fd2uid[fd] = uid
end

-- 下线一段时间后调用
function CMD.free_player(agent, uid)
    uid2agent[uid] = nil
    free_agents[agent] = true
    full_agents[agent] = nil
end

function CMD.reconnect(fd, uid, csn, ssn, passport, user_info)
    assert(fd)
    assert(uid)
    assert(csn and ssn)
    local agent = uid2agent[uid]
    if agent then
        return skynet.call(agent, "lua", "reconnect", fd, uid, csn, ssn, passport, user_info)
    end
end

function CMD.kick(uid)
    local agent = uid2agent[uid]
    if agent then
        skynet.call(agent, "lua", "kick", uid)
        uid2agent[uid] = nil
    end
end

function CMD.online_count()
    local count = 0
    for v, _ in pairs(free_agents) do
        count = count + skynet.call(v, "lua", "online_count")
    end
    for v, _ in pairs(full_agents) do
        count = count + skynet.call(v, "lua", "online_count")
    end
    return count
end

skynet.start(function()
	skynet.dispatch("lua", function(_, _, cmd, subcmd, ...)
        if cmd == "socket" then
            local f = SOCKET[subcmd]
            f(...)
            return
        elseif CMD[cmd] then
            bewater.ret(CMD[cmd](subcmd, ...))
        else
            local f = assert(server[cmd], cmd)
            if type(f) == "function" then
                bewater.ret(f(server, subcmd, ...))
            else
                bewater.ret(f[subcmd](f, ...))
            end
        end
    end)

   GATE = skynet.newservice("gate")
end)
