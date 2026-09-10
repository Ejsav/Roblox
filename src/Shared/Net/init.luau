--!strict
--[[
	Net
	---
	The single gateway for client/server traffic.

	Server responsibilities handled here so no service has to remember them:
	  * Rate limiting per player per remote (token bucket)
	  * Argument validation against the declared schema
	  * Rejection reporting, so the anti-cheat layer sees every malformed packet
	  * Handler error isolation — one throwing handler never kills the remote

	Client responsibilities:
	  * Refusing to send on remotes the client is not permitted to send on
	  * Local rate limiting, so an accidental input loop is caught before it becomes
	    a server-side suspicion event

	Remote instances live under ReplicatedStorage.BTS.Remotes and are created by the
	server at boot. Clients wait for them rather than creating them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(script.Remotes)
local Signal = require(script.Parent.Core.Signal)
local Validate = require(script.Parent.Core.Validate)
local RateLimiter = require(script.Parent.Core.RateLimiter)
local Balance = require(script.Parent.Config.Balance)

local Net = {}

local IS_SERVER = RunService:IsServer()

local FOLDER_NAME = "Remotes"

local remoteInstances: { [string]: Instance } = {}
local serverHandlers: { [string]: (Player, ...any) -> ...any } = {}
local clientHandlers: { [string]: { any } } = {}
local limiter = RateLimiter.new()
local clientLimiter = RateLimiter.new()

--[[ Fired whenever a client request is rejected. AntiCheatService listens. ]]
Net.RequestRejected = Signal.new("Net.RequestRejected")

--[[ Fired for every accepted client request, for analytics volume tracking. ]]
Net.RequestAccepted = Signal.new("Net.RequestAccepted")

local function now(): number
	return os.clock()
end

-- ============================================================================
-- Setup
-- ============================================================================

local function getFolder(): Instance?
	local btsRoot = ReplicatedStorage:FindFirstChild("BTS")
	if not btsRoot then
		return nil
	end
	return btsRoot:FindFirstChild(FOLDER_NAME)
end

--[[
	Creates every declared remote instance. Server only, called once during bootstrap.
]]
function Net.InitServer()
	assert(IS_SERVER, "Net.InitServer must be called on the server")

	local btsRoot = ReplicatedStorage:WaitForChild("BTS")
	local folder = btsRoot:FindFirstChild(FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = btsRoot
	end

	for _, name in ipairs(Remotes.GetNames()) do
		local existing = folder:FindFirstChild(name)
		if existing then
			remoteInstances[name] = existing
		else
			local className = Remotes.IsFunction(name) and "RemoteFunction" or "RemoteEvent"
			local remote = Instance.new(className)
			remote.Name = name
			remote.Parent = folder
			remoteInstances[name] = remote
		end
	end

	return folder
end

--[[ Resolves (and caches) a remote instance by name. ]]
local function resolveRemote(name: string): Instance?
	local cached = remoteInstances[name]
	if cached then
		return cached
	end
	local folder = getFolder()
	if not folder then
		return nil
	end
	local remote = folder:FindFirstChild(name)
	if remote then
		remoteInstances[name] = remote
	end
	return remote
end

--[[ Client-side: waits for the remote folder to replicate before use. ]]
function Net.InitClient(timeoutSeconds: number?)
	assert(not IS_SERVER, "Net.InitClient must be called on the client")
	local btsRoot = ReplicatedStorage:WaitForChild("BTS", timeoutSeconds or 30)
	if not btsRoot then
		return false
	end
	local folder = btsRoot:WaitForChild(FOLDER_NAME, timeoutSeconds or 30)
	if not folder then
		return false
	end
	for _, child in ipairs(folder:GetChildren()) do
		remoteInstances[child.Name] = child
	end
	folder.ChildAdded:Connect(function(child)
		remoteInstances[child.Name] = child
	end)
	return true
end

-- ============================================================================
-- Server API
-- ============================================================================

--[[
	Validates an inbound request against its declared schema and rate limit.
	Returns (ok, reason). On failure it fires Net.RequestRejected with full context.
]]
local function screenRequest(player: Player, name: string, args: { any }, argCount: number): (boolean, string?)
	local definition = Remotes.Get(name)
	if not definition then
		return false, "unknown_remote"
	end
	if not Remotes.IsClientSendable(name) then
		-- A client firing a server-to-client remote is never a mistake.
		return false, "wrong_direction"
	end

	local budget = definition.rateLimit or Balance.Network.DEFAULT_RATE_LIMIT
	local allowed = limiter:Consume(player.UserId, name, budget, now())
	if not allowed then
		return false, "rate_limited"
	end

	if definition.args then
		local ok, index, reason = Validate.Arguments(definition.args, args, argCount)
		if not ok then
			return false, ("invalid_argument_%d:%s"):format(index or 0, reason or "unknown")
		end
	elseif argCount > 0 then
		return false, "unexpected_arguments"
	end

	return true, nil
end

--[[
	Registers the server handler for a client-sendable remote.
	Only one handler per remote: the owning service. Fan-out happens through signals
	inside the service, not by stacking listeners on the network edge.
]]
function Net.OnServerEvent(name: string, handler: (Player, ...any) -> ())
	assert(IS_SERVER, "Net.OnServerEvent is server-only")
	assert(Remotes.Get(name), "unknown remote: " .. tostring(name))
	assert(not serverHandlers[name], "duplicate server handler for remote: " .. name)

	local remote = resolveRemote(name)
	assert(remote, "remote instance missing (call Net.InitServer first): " .. name)

	serverHandlers[name] = handler

	if remote:IsA("RemoteFunction") then
		(remote :: RemoteFunction).OnServerInvoke = function(player, ...)
			local args = table.pack(...)
			local ok, reason = screenRequest(player, name, args, args.n)
			if not ok then
				Net.RequestRejected:Fire(player, name, reason)
				return nil
			end
			Net.RequestAccepted:Fire(player, name)
			local success, result = pcall(handler, player, ...)
			if not success then
				warn(("[Net] handler error on %s: %s"):format(name, tostring(result)))
				return nil
			end
			return result
		end
	else
		(remote :: RemoteEvent).OnServerEvent:Connect(function(player, ...)
			local args = table.pack(...)
			local ok, reason = screenRequest(player, name, args, args.n)
			if not ok then
				Net.RequestRejected:Fire(player, name, reason)
				return
			end
			Net.RequestAccepted:Fire(player, name)
			local success, err = pcall(handler, player, ...)
			if not success then
				warn(("[Net] handler error on %s: %s"):format(name, tostring(err)))
			end
		end)
	end
end

--[[ Sends to one client. ]]
function Net.FireClient(player: Player, name: string, ...)
	assert(IS_SERVER, "Net.FireClient is server-only")
	local remote = resolveRemote(name)
	if not remote then
		warn("[Net] missing remote: " .. name)
		return
	end
	if remote:IsA("RemoteEvent") then
		(remote :: RemoteEvent):FireClient(player, ...)
	end
end

--[[ Sends to every client. Use sparingly; prefer interest-scoped FireClient. ]]
function Net.FireAllClients(name: string, ...)
	assert(IS_SERVER, "Net.FireAllClients is server-only")
	local remote = resolveRemote(name)
	if not remote then
		warn("[Net] missing remote: " .. name)
		return
	end
	if remote:IsA("RemoteEvent") then
		(remote :: RemoteEvent):FireAllClients(...)
	end
end

--[[ Sends to a specific list of clients. ]]
function Net.FireClients(players: { Player }, name: string, ...)
	assert(IS_SERVER, "Net.FireClients is server-only")
	local remote = resolveRemote(name)
	if not remote or not remote:IsA("RemoteEvent") then
		return
	end
	for _, player in ipairs(players) do
		(remote :: RemoteEvent):FireClient(player, ...)
	end
end

--[[ Releases a player's rate-limit buckets when they leave. ]]
function Net.ClearPlayer(player: Player)
	limiter:Clear(player.UserId)
end

--[[ Periodic maintenance; called from the server's slow tick. ]]
function Net.Sweep()
	limiter:Sweep(now())
end

function Net.GetLimiterStats(): { buckets: number }
	return { buckets = limiter:GetBucketCount() }
end

-- ============================================================================
-- Client API
-- ============================================================================

--[[
	Fires a remote to the server.
	Client-side rate limiting mirrors the server's budget so an input bug is caught
	locally instead of accumulating server-side suspicion.
]]
function Net.FireServer(name: string, ...): boolean
	assert(not IS_SERVER, "Net.FireServer is client-only")
	local definition = Remotes.Get(name)
	if not definition then
		warn("[Net] unknown remote: " .. tostring(name))
		return false
	end
	if not Remotes.IsClientSendable(name) then
		warn("[Net] client may not send on: " .. name)
		return false
	end

	local budget = definition.rateLimit or Balance.Network.DEFAULT_RATE_LIMIT
	if not clientLimiter:Consume("local", name, budget, now()) then
		return false
	end

	local remote = resolveRemote(name)
	if not remote then
		warn("[Net] missing remote instance: " .. name)
		return false
	end
	if remote:IsA("RemoteEvent") then
		(remote :: RemoteEvent):FireServer(...)
		return true
	end
	return false
end

--[[ Invokes a RemoteFunction on the server. Yields. ]]
function Net.InvokeServer(name: string, ...): any
	assert(not IS_SERVER, "Net.InvokeServer is client-only")
	local definition = Remotes.Get(name)
	if not definition or definition.direction ~= "C2SF" then
		warn("[Net] not an invokable remote: " .. tostring(name))
		return nil
	end

	local budget = definition.rateLimit or Balance.Network.DEFAULT_RATE_LIMIT
	if not clientLimiter:Consume("local", name, budget, now()) then
		return nil
	end

	local remote = resolveRemote(name)
	if not remote or not remote:IsA("RemoteFunction") then
		return nil
	end
	local ok, result = pcall(function(...)
		return (remote :: RemoteFunction):InvokeServer(...)
	end, ...)
	if not ok then
		warn(("[Net] invoke failed on %s: %s"):format(name, tostring(result)))
		return nil
	end
	return result
end

--[[
	Subscribes to a server-to-client remote. Unlike the server side, multiple client
	listeners are allowed — several controllers legitimately care about CarryUpdate.
]]
function Net.OnClientEvent(name: string, handler: (...any) -> ())
	assert(not IS_SERVER, "Net.OnClientEvent is client-only")
	assert(Remotes.Get(name), "unknown remote: " .. tostring(name))

	local handlers = clientHandlers[name]
	if not handlers then
		handlers = {}
		clientHandlers[name] = handlers

		local remote = resolveRemote(name)
		if not remote then
			warn("[Net] missing remote instance: " .. name)
			return { Disconnect = function() end }
		end
		if remote:IsA("RemoteEvent") then
			(remote :: RemoteEvent).OnClientEvent:Connect(function(...)
				for _, listener in ipairs(clientHandlers[name] or {}) do
					local ok, err = pcall(listener, ...)
					if not ok then
						warn(("[Net] client handler error on %s: %s"):format(name, tostring(err)))
					end
				end
			end)
		end
	end

	table.insert(handlers, handler)

	return {
		Disconnect = function()
			local list = clientHandlers[name]
			if not list then
				return
			end
			for index, listener in ipairs(list) do
				if listener == handler then
					table.remove(list, index)
					break
				end
			end
		end,
	}
end

Net.Remotes = Remotes

return Net
