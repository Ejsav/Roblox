--!nolint
--[[
	RobloxMock
	----------
	A pragmatic emulation of the slice of the Roblox API that BORROW THE STORM's
	pure-logic modules touch, so that progression math, loot tables, data migration,
	quest state machines and config validation can be unit tested outside Studio.

	This is deliberately NOT a full engine. Rendering, physics and replication are out
	of scope. What it does provide:
	  * Instance.new with property bags, hierarchy, Destroy, and the common query methods
	  * Vector2 / Vector3 / CFrame (translation + basic rotation) / Color3 / UDim / UDim2
	  * A permissive Enum proxy (any Enum.Foo.Bar resolves to a comparable sentinel)
	  * A cooperative `task` scheduler with a virtual clock so time-based logic can be
	    fast-forwarded deterministically in tests
	  * game:GetService() returning persistent service stubs
]]

local Mock = {}

-- When `captureWarnings` is true, warn() output is collected here instead of printed,
-- so specs can assert on warning behaviour without polluting the report.
Mock.warnings = {}
Mock.captureWarnings = false
Mock.silenceWarnings = false

-- ============================================================================
-- Virtual clock + cooperative scheduler
-- ============================================================================

local Scheduler = {}
Scheduler.now = 0
Scheduler.queue = {} -- array of { time, thread, args }
Scheduler.seq = 0

function Scheduler.reset()
	Scheduler.now = 0
	Scheduler.queue = {}
	Scheduler.seq = 0
end

function Scheduler.schedule(delay, thread, args)
	Scheduler.seq += 1
	table.insert(Scheduler.queue, {
		time = Scheduler.now + math.max(0, delay or 0),
		seq = Scheduler.seq,
		thread = thread,
		args = args or {},
		cancelled = false,
	})
end

--[[ Advances the virtual clock by `seconds`, running everything due along the way. ]]
function Scheduler.advance(seconds)
	local target = Scheduler.now + seconds
	local guard = 0
	while true do
		guard += 1
		if guard > 100000 then
			error("Scheduler.advance: runaway task loop (>100000 iterations)")
		end
		-- Find the earliest pending entry at or before the target time.
		local bestIndex, best = nil, nil
		for i, entry in ipairs(Scheduler.queue) do
			if not entry.cancelled and entry.time <= target then
				if not best or entry.time < best.time or (entry.time == best.time and entry.seq < best.seq) then
					bestIndex, best = i, entry
				end
			end
		end
		if not best then
			break
		end
		table.remove(Scheduler.queue, bestIndex)
		Scheduler.now = best.time
		if coroutine.status(best.thread) == "suspended" then
			local ok, err = coroutine.resume(best.thread, table.unpack(best.args))
			if not ok then
				warn("[MockScheduler] task error: " .. tostring(err))
			end
		end
	end
	Scheduler.now = target
end

Mock.Scheduler = Scheduler

-- ============================================================================
-- Vector2 / Vector3
-- ============================================================================

local Vector3Mt = {}
Vector3Mt.__index = Vector3Mt

local function v3(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3Mt)
end

function Vector3Mt.__add(a, b)
	return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
function Vector3Mt.__sub(a, b)
	return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
function Vector3Mt.__mul(a, b)
	if type(a) == "number" then
		return v3(a * b.X, a * b.Y, a * b.Z)
	elseif type(b) == "number" then
		return v3(a.X * b, a.Y * b, a.Z * b)
	end
	return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
function Vector3Mt.__div(a, b)
	if type(b) == "number" then
		return v3(a.X / b, a.Y / b, a.Z / b)
	end
	return v3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
function Vector3Mt.__unm(a)
	return v3(-a.X, -a.Y, -a.Z)
end
function Vector3Mt.__eq(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
function Vector3Mt.__tostring(a)
	return string.format("%.3f, %.3f, %.3f", a.X, a.Y, a.Z)
end

function Vector3Mt:Dot(other)
	return self.X * other.X + self.Y * other.Y + self.Z * other.Z
end
function Vector3Mt:Cross(other)
	return v3(
		self.Y * other.Z - self.Z * other.Y,
		self.Z * other.X - self.X * other.Z,
		self.X * other.Y - self.Y * other.X
	)
end
function Vector3Mt:Lerp(other, t)
	return v3(
		self.X + (other.X - self.X) * t,
		self.Y + (other.Y - self.Y) * t,
		self.Z + (other.Z - self.Z) * t
	)
end
function Vector3Mt:FuzzyEq(other, epsilon)
	local e = epsilon or 1e-5
	return math.abs(self.X - other.X) <= e and math.abs(self.Y - other.Y) <= e and math.abs(self.Z - other.Z) <= e
end

Vector3Mt.__index = function(self, key)
	if key == "Magnitude" then
		return math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
	elseif key == "Unit" then
		local m = math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
		if m == 0 then
			return v3(0, 0, 0)
		end
		return v3(self.X / m, self.Y / m, self.Z / m)
	end
	return rawget(Vector3Mt, key)
end

local Vector3 = setmetatable({
	new = v3,
	zero = v3(0, 0, 0),
	one = v3(1, 1, 1),
	xAxis = v3(1, 0, 0),
	yAxis = v3(0, 1, 0),
	zAxis = v3(0, 0, 1),
}, { __call = function(_, x, y, z) return v3(x, y, z) end })
Mock.Vector3 = Vector3

local Vector2Mt = {}
local function v2(x, y)
	return setmetatable({ X = x or 0, Y = y or 0 }, Vector2Mt)
end
Vector2Mt.__index = function(self, key)
	if key == "Magnitude" then
		return math.sqrt(self.X * self.X + self.Y * self.Y)
	elseif key == "Unit" then
		local m = math.sqrt(self.X * self.X + self.Y * self.Y)
		return m == 0 and v2(0, 0) or v2(self.X / m, self.Y / m)
	end
	return rawget(Vector2Mt, key)
end
Vector2Mt.__add = function(a, b) return v2(a.X + b.X, a.Y + b.Y) end
Vector2Mt.__sub = function(a, b) return v2(a.X - b.X, a.Y - b.Y) end
Vector2Mt.__mul = function(a, b)
	if type(b) == "number" then return v2(a.X * b, a.Y * b) end
	if type(a) == "number" then return v2(a * b.X, a * b.Y) end
	return v2(a.X * b.X, a.Y * b.Y)
end
Vector2Mt.__eq = function(a, b) return a.X == b.X and a.Y == b.Y end
Mock.Vector2 = { new = v2, zero = v2(0, 0), one = v2(1, 1) }

-- ============================================================================
-- CFrame (position + orthonormal basis; enough for placement math)
-- ============================================================================

local CFrameMt = {}
CFrameMt.__index = CFrameMt

local function cframe(pos, rx, ry, rz)
	return setmetatable({
		Position = pos or v3(0, 0, 0),
		_rx = rx or 0,
		_ry = ry or 0,
		_rz = rz or 0,
	}, CFrameMt)
end

CFrameMt.__index = function(self, key)
	if key == "X" then return self.Position.X end
	if key == "Y" then return self.Position.Y end
	if key == "Z" then return self.Position.Z end
	if key == "LookVector" then
		local cy, sy = math.cos(self._ry), math.sin(self._ry)
		return v3(-sy, 0, -cy).Unit
	end
	if key == "RightVector" then
		local cy, sy = math.cos(self._ry), math.sin(self._ry)
		return v3(cy, 0, -sy)
	end
	if key == "UpVector" then return v3(0, 1, 0) end
	if key == "Rotation" then return cframe(v3(0, 0, 0), self._rx, self._ry, self._rz) end
	return rawget(CFrameMt, key)
end

CFrameMt.__mul = function(a, b)
	if getmetatable(b) == Vector3Mt then
		return a.Position + b
	end
	return cframe(a.Position + b.Position, a._rx + b._rx, a._ry + b._ry, a._rz + b._rz)
end
CFrameMt.__add = function(a, b) return cframe(a.Position + b, a._rx, a._ry, a._rz) end
CFrameMt.__sub = function(a, b) return cframe(a.Position - b, a._rx, a._ry, a._rz) end
CFrameMt.__tostring = function(a) return "CFrame(" .. tostring(a.Position) .. ")" end

function CFrameMt:ToWorldSpace(other)
	return cframe(self.Position + other.Position, self._rx + other._rx, self._ry + other._ry, self._rz + other._rz)
end
function CFrameMt:ToObjectSpace(other)
	return cframe(other.Position - self.Position, other._rx - self._rx, other._ry - self._ry, other._rz - self._rz)
end
function CFrameMt:PointToWorldSpace(p)
	return self.Position + p
end
function CFrameMt:Lerp(other, t)
	return cframe(self.Position:Lerp(other.Position, t), self._rx, self._ry, self._rz)
end
function CFrameMt:Inverse()
	return cframe(-self.Position, -self._rx, -self._ry, -self._rz)
end

local CFrame = {
	new = function(x, y, z)
		if type(x) == "table" then
			return cframe(x)
		end
		return cframe(v3(x or 0, y or 0, z or 0))
	end,
	identity = cframe(v3(0, 0, 0)),
	Angles = function(rx, ry, rz)
		return cframe(v3(0, 0, 0), rx, ry, rz)
	end,
	fromEulerAnglesXYZ = function(rx, ry, rz)
		return cframe(v3(0, 0, 0), rx, ry, rz)
	end,
	lookAt = function(from, to)
		local dir = (to - from)
		local ry = math.atan2(-dir.X, -dir.Z)
		return cframe(from, 0, ry, 0)
	end,
}
CFrame.fromOrientation = CFrame.Angles
Mock.CFrame = CFrame

-- ============================================================================
-- Color3 / UDim / UDim2 / NumberRange / TweenInfo
-- ============================================================================

local Color3Mt = { __index = {} }
local function c3(r, g, b)
	return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, Color3Mt)
end
Color3Mt.__eq = function(a, b) return a.R == b.R and a.G == b.G and a.B == b.B end
Color3Mt.__tostring = function(a) return string.format("%.3f, %.3f, %.3f", a.R, a.G, a.B) end
function Color3Mt.__index.Lerp(self, other, t)
	return c3(self.R + (other.R - self.R) * t, self.G + (other.G - self.G) * t, self.B + (other.B - self.B) * t)
end
function Color3Mt.__index.ToHSV(self)
	local r, g, b = self.R, self.G, self.B
	local maxV, minV = math.max(r, g, b), math.min(r, g, b)
	local delta = maxV - minV
	local h = 0
	if delta > 0 then
		if maxV == r then
			h = ((g - b) / delta) % 6
		elseif maxV == g then
			h = (b - r) / delta + 2
		else
			h = (r - g) / delta + 4
		end
		h /= 6
	end
	local s = maxV == 0 and 0 or delta / maxV
	return h, s, maxV
end

Mock.Color3 = {
	new = c3,
	fromRGB = function(r, g, b) return c3((r or 0) / 255, (g or 0) / 255, (b or 0) / 255) end,
	fromHex = function(hex)
		hex = hex:gsub("#", "")
		return c3(
			tonumber(hex:sub(1, 2), 16) / 255,
			tonumber(hex:sub(3, 4), 16) / 255,
			tonumber(hex:sub(5, 6), 16) / 255
		)
	end,
	fromHSV = function(h, s, v)
		local i = math.floor(h * 6)
		local f = h * 6 - i
		local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
		local m = i % 6
		if m == 0 then return c3(v, t, p) end
		if m == 1 then return c3(q, v, p) end
		if m == 2 then return c3(p, v, t) end
		if m == 3 then return c3(p, q, v) end
		if m == 4 then return c3(t, p, v) end
		return c3(v, p, q)
	end,
}

local UDimMt = { __index = {} }
local function udim(scale, offset)
	return setmetatable({ Scale = scale or 0, Offset = offset or 0 }, UDimMt)
end
UDimMt.__add = function(a, b) return udim(a.Scale + b.Scale, a.Offset + b.Offset) end
Mock.UDim = { new = udim }

local UDim2Mt = { __index = {} }
local function udim2(xs, xo, ys, yo)
	return setmetatable({ X = udim(xs, xo), Y = udim(ys, yo) }, UDim2Mt)
end
UDim2Mt.__add = function(a, b)
	return udim2(a.X.Scale + b.X.Scale, a.X.Offset + b.X.Offset, a.Y.Scale + b.Y.Scale, a.Y.Offset + b.Y.Offset)
end
UDim2Mt.__sub = function(a, b)
	return udim2(a.X.Scale - b.X.Scale, a.X.Offset - b.X.Offset, a.Y.Scale - b.Y.Scale, a.Y.Offset - b.Y.Offset)
end
function UDim2Mt.__index.Lerp(self, other, t)
	return udim2(
		self.X.Scale + (other.X.Scale - self.X.Scale) * t,
		self.X.Offset + (other.X.Offset - self.X.Offset) * t,
		self.Y.Scale + (other.Y.Scale - self.Y.Scale) * t,
		self.Y.Offset + (other.Y.Offset - self.Y.Offset) * t
	)
end
Mock.UDim2 = {
	new = udim2,
	fromScale = function(x, y) return udim2(x, 0, y, 0) end,
	fromOffset = function(x, y) return udim2(0, x, 0, y) end,
}

Mock.NumberRange = { new = function(a, b) return { Min = a, Max = b or a } end }
Mock.NumberSequence = { new = function(a, b) return { Keypoints = { a, b } } end }
Mock.NumberSequenceKeypoint = { new = function(t, v, e) return { Time = t, Value = v, Envelope = e or 0 } end }
Mock.ColorSequence = { new = function(a, b) return { Keypoints = { a, b } } end }
Mock.ColorSequenceKeypoint = { new = function(t, v) return { Time = t, Value = v } end }
Mock.TweenInfo = {
	new = function(time, style, direction, repeatCount, reverses, delayTime)
		return {
			Time = time or 1,
			EasingStyle = style,
			EasingDirection = direction,
			RepeatCount = repeatCount or 0,
			Reverses = reverses or false,
			DelayTime = delayTime or 0,
		}
	end,
}
Mock.Rect = { new = function(a, b) return { Min = a, Max = b } end }
Mock.Region3 = { new = function(a, b) return { Min = a, Max = b } end }
Mock.Ray = { new = function(o, d) return { Origin = o, Direction = d } end }

-- ============================================================================
-- Enum proxy: any Enum.Category.Item resolves to a stable comparable sentinel.
-- ============================================================================

local enumItemCache = {}
local function makeEnumCategory(categoryName)
	return setmetatable({}, {
		__index = function(_, itemName)
			local key = categoryName .. "." .. itemName
			local cached = enumItemCache[key]
			if not cached then
				cached = setmetatable({
					Name = itemName,
					Value = #enumItemCache,
					EnumType = categoryName,
				}, {
					__tostring = function() return "Enum." .. key end,
				})
				enumItemCache[key] = cached
			end
			return cached
		end,
		__tostring = function() return "Enum." .. categoryName end,
	})
end

local enumCategoryCache = {}
Mock.Enum = setmetatable({}, {
	__index = function(_, categoryName)
		local cached = enumCategoryCache[categoryName]
		if not cached then
			cached = makeEnumCategory(categoryName)
			enumCategoryCache[categoryName] = cached
		end
		return cached
	end,
})

-- ============================================================================
-- RBXScriptSignal
-- ============================================================================

local MockSignal = {}
MockSignal.__index = MockSignal

local function newSignal()
	return setmetatable({ _handlers = {} }, MockSignal)
end

function MockSignal:Connect(fn)
	local handler = { fn = fn, connected = true }
	table.insert(self._handlers, handler)
	return {
		Connected = true,
		Disconnect = function(selfConn)
			handler.connected = false
			if type(selfConn) == "table" then
				selfConn.Connected = false
			end
		end,
		Destroy = function()
			handler.connected = false
		end,
	}
end
MockSignal.Once = MockSignal.Connect
MockSignal.ConnectParallel = MockSignal.Connect

function MockSignal:Fire(...)
	for _, handler in ipairs(table.clone(self._handlers)) do
		if handler.connected then
			local ok, err = pcall(handler.fn, ...)
			if not ok then
				warn("[MockSignal] " .. tostring(err))
			end
		end
	end
end

function MockSignal:Wait()
	return nil
end

Mock.newSignal = newSignal

-- ============================================================================
-- Instance
-- ============================================================================

local InstanceMt = {}

local DEFAULT_PROPERTIES = {
	BasePart = { Anchored = false, CanCollide = true, Transparency = 0, Size = v3(4, 1, 2) },
}

local function newInstance(className, parent)
	local self
	local props = {
		Name = className,
		ClassName = className,
		Archivable = true,
		Parent = nil,
	}
	local children = {}
	local attributes = {}
	local signals = {}
	local tags = {}

	local function getSignal(name)
		if not signals[name] then
			signals[name] = newSignal()
		end
		return signals[name]
	end

	local methods = {}

	function methods.IsA(_, class)
		if props.ClassName == class then
			return true
		end
		-- Coarse inheritance map, sufficient for our guard clauses.
		local inheritance = {
			Part = { "BasePart", "PVInstance", "Instance" },
			MeshPart = { "BasePart", "PVInstance", "Instance" },
			WedgePart = { "BasePart", "PVInstance", "Instance" },
			UnionOperation = { "BasePart", "PVInstance", "Instance" },
			TrussPart = { "BasePart", "PVInstance", "Instance" },
			Model = { "PVInstance", "Instance" },
			Frame = { "GuiObject", "GuiBase2d", "Instance" },
			TextLabel = { "GuiObject", "GuiBase2d", "Instance" },
			TextButton = { "GuiButton", "GuiObject", "GuiBase2d", "Instance" },
			ImageLabel = { "GuiObject", "GuiBase2d", "Instance" },
			ImageButton = { "GuiButton", "GuiObject", "GuiBase2d", "Instance" },
			ScrollingFrame = { "GuiObject", "GuiBase2d", "Instance" },
			TextBox = { "GuiObject", "GuiBase2d", "Instance" },
			ModuleScript = { "LuaSourceContainer", "Instance" },
			Script = { "BaseScript", "LuaSourceContainer", "Instance" },
			LocalScript = { "BaseScript", "LuaSourceContainer", "Instance" },
			RemoteEvent = { "Instance" },
			RemoteFunction = { "Instance" },
			Folder = { "Instance" },
			Humanoid = { "Instance" },
			Attachment = { "Instance" },
		}
		local chain = inheritance[props.ClassName]
		if chain then
			for _, ancestor in ipairs(chain) do
				if ancestor == class then
					return true
				end
			end
		end
		return class == "Instance"
	end

	function methods.GetChildren()
		return table.clone(children)
	end

	function methods.GetDescendants()
		local out = {}
		local function walk(node)
			for _, child in ipairs(node:GetChildren()) do
				table.insert(out, child)
				walk(child)
			end
		end
		walk(self)
		return out
	end

	function methods.FindFirstChild(_, name, recursive)
		for _, child in ipairs(children) do
			if child.Name == name then
				return child
			end
		end
		if recursive then
			for _, child in ipairs(children) do
				local found = child:FindFirstChild(name, true)
				if found then
					return found
				end
			end
		end
		return nil
	end

	function methods.FindFirstChildOfClass(_, class)
		for _, child in ipairs(children) do
			if child.ClassName == class then
				return child
			end
		end
		return nil
	end
	methods.FindFirstChildWhichIsA = function(_, class)
		for _, child in ipairs(children) do
			if child:IsA(class) then
				return child
			end
		end
		return nil
	end

	function methods.FindFirstAncestor(_, name)
		local node = props.Parent
		while node do
			if node.Name == name then
				return node
			end
			node = node.Parent
		end
		return nil
	end
	methods.FindFirstAncestorOfClass = function(_, class)
		local node = props.Parent
		while node do
			if node.ClassName == class then
				return node
			end
			node = node.Parent
		end
		return nil
	end

	function methods.WaitForChild(_, name)
		return methods.FindFirstChild(nil, name)
	end

	function methods.ClearAllChildren()
		for _, child in ipairs(table.clone(children)) do
			child:Destroy()
		end
	end

	function methods.Destroy()
		methods.ClearAllChildren()
		if props.Parent then
			local siblings = props.Parent._children
			if siblings then
				for i, sibling in ipairs(siblings) do
					if sibling == self then
						table.remove(siblings, i)
						break
					end
				end
			end
		end
		props.Parent = nil
		self._destroyed = true
		getSignal("Destroying"):Fire()
	end
	methods.Remove = methods.Destroy

	function methods.Clone()
		local copy = newInstance(props.ClassName)
		for key, value in pairs(props) do
			if key ~= "Parent" then
				copy[key] = value
			end
		end
		for key, value in pairs(attributes) do
			copy:SetAttribute(key, value)
		end
		for _, child in ipairs(children) do
			local childCopy = child:Clone()
			childCopy.Parent = copy
		end
		return copy
	end

	function methods.SetAttribute(_, key, value)
		attributes[key] = value
		getSignal("AttributeChanged"):Fire(key)
	end
	function methods.GetAttribute(_, key)
		return attributes[key]
	end
	function methods.GetAttributes()
		return table.clone(attributes)
	end
	function methods.GetAttributeChangedSignal(_, _key)
		return getSignal("AttributeChanged")
	end
	function methods.GetPropertyChangedSignal(_, key)
		return getSignal("Changed:" .. key)
	end
	function methods.AddTag(_, tag)
		tags[tag] = true
	end
	function methods.RemoveTag(_, tag)
		tags[tag] = nil
	end
	function methods.HasTag(_, tag)
		return tags[tag] == true
	end
	function methods.GetTags()
		local out = {}
		for tag in pairs(tags) do
			table.insert(out, tag)
		end
		return out
	end
	function methods.IsDescendantOf(_, ancestor)
		local node = props.Parent
		while node do
			if node == ancestor then
				return true
			end
			node = node.Parent
		end
		return false
	end
	function methods.PivotTo(_, cf)
		props.CFrame = cf
		props.Position = cf.Position
	end
	function methods.GetPivot()
		return props.CFrame or cframe(props.Position or v3(0, 0, 0))
	end
	function methods.SetPrimaryPartCFrame(_, cf)
		props.CFrame = cf
	end
	function methods.GetBoundingBox()
		return props.CFrame or cframe(v3(0, 0, 0)), props.Size or v3(1, 1, 1)
	end
	function methods.FireServer() end
	function methods.FireClient() end
	function methods.FireAllClients() end
	function methods.InvokeServer() end
	function methods.InvokeClient() end

	self = setmetatable({
		_props = props,
		_children = children,
		_signals = signals,
		_methods = methods,
		_destroyed = false,
	}, InstanceMt)

	local defaults = DEFAULT_PROPERTIES[className]
	if defaults then
		for key, value in pairs(defaults) do
			props[key] = value
		end
	end
	-- Every instance exposes these signals regardless of class.
	getSignal("ChildAdded")
	getSignal("ChildRemoved")
	getSignal("AncestryChanged")
	getSignal("Destroying")

	if parent then
		self.Parent = parent
	end
	return self
end

--[[
	GUI event names that a component may connect to. Constructing a screen touches
	most of these, and a screen that cannot be constructed in a test is a screen
	whose build path is never exercised until a player opens it.
]]
local GUI_EVENTS = {
	Activated = true,
	MouseButton1Click = true,
	MouseButton1Down = true,
	MouseButton1Up = true,
	MouseButton2Click = true,
	MouseEnter = true,
	MouseLeave = true,
	MouseMoved = true,
	MouseWheelForward = true,
	MouseWheelBackward = true,
	SelectionGained = true,
	SelectionLost = true,
	TouchTap = true,
	TouchLongPress = true,
	TouchSwipe = true,
	Triggered = true,
	Destroying = true,
	Heartbeat = true,
	Stepped = true,
	RenderStepped = true,
}

InstanceMt.__index = function(self, key)
	local props = rawget(self, "_props")
	if props[key] ~= nil then
		return props[key]
	end
	local methods = rawget(self, "_methods")
	if methods[key] then
		return methods[key]
	end
	local signals = rawget(self, "_signals")
	if signals[key] then
		return signals[key]
	end
	-- Instance children are addressable as properties, matching Roblox behaviour.
	for _, child in ipairs(rawget(self, "_children")) do
		if child.Name == key then
			return child
		end
	end
	-- Common event names are lazily created so :Connect never errors in tests.
	-- GUI input events are listed rather than pattern-matched: "Activated" and
	-- "MouseEnter" share no useful shape with each other, and a pattern loose
	-- enough to catch both would start swallowing genuine typos.
	if GUI_EVENTS[key]
		or key:match("^On")
		or key:match("Event$")
		or key:match("Changed$")
		or key:match("Began$")
		or key:match("Ended$")
	then
		local sig = newSignal()
		signals[key] = sig
		return sig
	end
	return nil
end

InstanceMt.__newindex = function(self, key, value)
	local props = rawget(self, "_props")
	if key == "Parent" then
		local old = props.Parent
		if old then
			for i, child in ipairs(old._children) do
				if child == self then
					table.remove(old._children, i)
					break
				end
			end
			old._signals.ChildRemoved:Fire(self)
		end
		props.Parent = value
		if value then
			table.insert(value._children, self)
			if value._signals and value._signals.ChildAdded then
				value._signals.ChildAdded:Fire(self)
			end
		end
		return
	end
	props[key] = value
	local signals = rawget(self, "_signals")
	if signals["Changed:" .. key] then
		signals["Changed:" .. key]:Fire(value)
	end
	if signals.Changed then
		signals.Changed:Fire(key)
	end
end

InstanceMt.__tostring = function(self)
	return rawget(self, "_props").Name
end

Mock.Instance = {
	new = function(className, parent)
		return newInstance(className, parent)
	end,
	fromExisting = function(other)
		return other:Clone()
	end,
}

-- ============================================================================
-- Services & game
-- ============================================================================

local services = {}

local function makeService(className, configure)
	local service = newInstance(className)
	service.Name = className
	if configure then
		configure(service)
	end
	services[className] = service
	return service
end

makeService("ReplicatedStorage")
makeService("ServerScriptService")
makeService("ServerStorage")
makeService("Workspace", function(s)
	s.Terrain = newInstance("Terrain", s)
	s.Gravity = 196.2
	s.CurrentCamera = newInstance("Camera", s)
	s.Raycast = function()
		return nil
	end
	s.GetPartBoundsInBox = function()
		return {}
	end
	s.GetPartBoundsInRadius = function()
		return {}
	end
end)
makeService("Lighting")
makeService("SoundService")
makeService("StarterGui", function(s)
	s.SetCore = function() end
	s.SetCoreGuiEnabled = function() end
end)
makeService("StarterPlayer")
makeService("TweenService", function(s)
	s.Create = function(_, instance, _info, goals)
		return {
			Play = function()
				for key, value in pairs(goals) do
					instance[key] = value
				end
			end,
			Cancel = function() end,
			Pause = function() end,
			Completed = newSignal(),
		}
	end
	s.GetValue = function(_, alpha)
		return alpha
	end
end)
makeService("RunService", function(s)
	s.IsServer = function()
		return true
	end
	s.IsClient = function()
		return false
	end
	s.IsStudio = function()
		return true
	end
	s.IsRunMode = function()
		return true
	end
	s.Heartbeat = newSignal()
	s.RenderStepped = newSignal()
	s.Stepped = newSignal()
	s.PreRender = newSignal()
	s.PostSimulation = newSignal()
	s.PreSimulation = newSignal()
	s.BindToRenderStep = function() end
	s.UnbindFromRenderStep = function() end
end)
makeService("Players", function(s)
	-- A LocalPlayer with no Character, which is what a real client looks like
	-- between joining and spawning. Client code reads LocalPlayer unconditionally
	-- (it is never nil on a client) but must tolerate a nil Character, and this is
	-- the state that catches the difference.
	local localPlayer = newInstance("Player")
	localPlayer.Name = "LocalPlayer"
	localPlayer.UserId = 1
	localPlayer.DisplayName = "LocalPlayer"
	localPlayer.Character = nil

	local playerGui = newInstance("ScreenGui", localPlayer)
	playerGui.Name = "PlayerGui"

	localPlayer.Parent = s

	s.LocalPlayer = localPlayer
	s.PlayerAdded = newSignal()
	s.PlayerRemoving = newSignal()
	s.GetPlayers = function()
		return s:GetChildren()
	end
	s.GetPlayerByUserId = function(_, userId)
		for _, player in ipairs(s:GetChildren()) do
			if player.UserId == userId then
				return player
			end
		end
		return nil
	end
	s.GetNameFromUserIdAsync = function(_, userId)
		return "User" .. tostring(userId)
	end
	s.CharacterAutoLoads = true
end)
makeService("HttpService", function(s)
	s.GenerateGUID = function(_, wrap)
		local chars = {}
		for i = 1, 32 do
			chars[i] = string.format("%x", math.random(0, 15))
		end
		local guid = table.concat(chars)
		return wrap == false and guid or ("{" .. guid .. "}")
	end
	s.JSONEncode = function(_, value)
		-- Minimal encoder: sufficient for analytics payload shape assertions.
		local function encode(v)
			local t = type(v)
			if t == "nil" then
				return "null"
			elseif t == "boolean" then
				return tostring(v)
			elseif t == "number" then
				return tostring(v)
			elseif t == "string" then
				return '"' .. v:gsub('[%c"\\]', function(c)
					return string.format("\\u%04x", string.byte(c))
				end) .. '"'
			elseif t == "table" then
				local isArray = #v > 0
				local parts = {}
				if isArray then
					for _, item in ipairs(v) do
						table.insert(parts, encode(item))
					end
					return "[" .. table.concat(parts, ",") .. "]"
				end
				local keys = {}
				for key in pairs(v) do
					table.insert(keys, tostring(key))
				end
				table.sort(keys)
				for _, key in ipairs(keys) do
					table.insert(parts, encode(key) .. ":" .. encode(v[key]))
				end
				return "{" .. table.concat(parts, ",") .. "}"
			end
			return "null"
		end
		return encode(value)
	end
	s.JSONDecode = function(_, _str)
		return {}
	end
end)
makeService("DataStoreService")
makeService("MessagingService", function(s)
	s.PublishAsync = function() end
	s.SubscribeAsync = function()
		return { Disconnect = function() end }
	end
end)
makeService("MarketplaceService", function(s)
	s.PromptProductPurchase = function() end
	s.PromptGamePassPurchase = function() end
	s.UserOwnsGamePassAsync = function()
		return false
	end
	s.GetProductInfo = function()
		return { Name = "Mock", PriceInRobux = 0 }
	end
	s.ProcessReceipt = nil
	s.PromptGamePassPurchaseFinished = newSignal()
end)
makeService("UserInputService", function(s)
	s.TouchEnabled = false
	s.KeyboardEnabled = true
	s.MouseEnabled = true
	s.GamepadEnabled = false
	s.InputBegan = newSignal()
	s.InputEnded = newSignal()
	s.InputChanged = newSignal()
	s.LastInputTypeChanged = newSignal()
	-- Touch gestures. Named individually because they do not share a suffix the
	-- lazy signal rule could match.
	s.TouchPinch = newSignal()
	s.TouchPan = newSignal()
	s.TouchTap = newSignal()
	s.TouchLongPress = newSignal()
	s.TouchSwipe = newSignal()
	s.TouchRotate = newSignal()
	s.GetConnectedGamepads = function()
		return {}
	end
	s.IsKeyDown = function()
		return false
	end
end)
makeService("ContextActionService", function(s)
	s.BindAction = function() end
	s.UnbindAction = function() end
	s.SetTitle = function() end
	s.SetImage = function() end
end)
makeService("GuiService", function(s)
	s.GetGuiInset = function()
		return v2(0, 36), v2(0, 0)
	end
	s.SelectedObject = nil
	s.MenuOpened = newSignal()
	s.MenuClosed = newSignal()
end)
makeService("CollectionService", function(s)
	local tagged = {}
	s.AddTag = function(_, instance, tag)
		tagged[tag] = tagged[tag] or {}
		table.insert(tagged[tag], instance)
	end
	s.RemoveTag = function(_, instance, tag)
		local list = tagged[tag]
		if list then
			for i, item in ipairs(list) do
				if item == instance then
					table.remove(list, i)
					break
				end
			end
		end
	end
	s.GetTagged = function(_, tag)
		return table.clone(tagged[tag] or {})
	end
	s.HasTag = function(_, instance, tag)
		for _, item in ipairs(tagged[tag] or {}) do
			if item == instance then
				return true
			end
		end
		return false
	end
	s.GetInstanceAddedSignal = function()
		return newSignal()
	end
	s.GetInstanceRemovedSignal = function()
		return newSignal()
	end
end)
makeService("Debris", function(s)
	s.AddItem = function(_, instance, lifetime)
		task.delay(lifetime or 0, function()
			if instance and instance.Destroy then
				instance:Destroy()
			end
		end)
	end
end)
makeService("PhysicsService", function(s)
	s.RegisterCollisionGroup = function() end
	s.CollisionGroupSetCollidable = function() end
end)
makeService("TextService")
makeService("LocalizationService")
makeService("TeleportService")
makeService("AnalyticsService", function(s)
	s.LogCustomEvent = function() end
	s.LogEconomyEvent = function() end
	s.LogProgressionEvent = function() end
	s.LogOnboardingFunnelStepEvent = function() end
end)
makeService("MemoryStoreService")
makeService("ContentProvider", function(s)
	s.PreloadAsync = function() end
end)
makeService("Chat")
makeService("TextChatService")
makeService("VoiceChatService")
makeService("BadgeService", function(s)
	s.AwardBadge = function()
		return true
	end
	s.UserHasBadgeAsync = function()
		return false
	end
end)
makeService("HapticService", function(s)
	s.SetMotor = function() end
	s.IsMotorSupported = function()
		return false
	end
end)

local gameInstance = newInstance("DataModel")
gameInstance.Name = "Game"
gameInstance.PlaceId = 0
gameInstance.JobId = "mock-job"
gameInstance.GetService = function(_, name)
	local service = services[name]
	if not service then
		service = makeService(name)
	end
	if service.Parent == nil then
		rawget(service, "_props").Parent = gameInstance
		table.insert(rawget(gameInstance, "_children"), service)
	end
	return service
end
gameInstance.FindService = gameInstance.GetService
gameInstance.BindToClose = function(_, fn)
	Mock._bindToClose = fn
end
gameInstance.SetPlaceId = function() end
gameInstance.Close = newSignal()

-- Attach all services to the DataModel so game.Workspace-style access works.
for name, service in pairs(services) do
	rawget(service, "_props").Parent = gameInstance
	table.insert(rawget(gameInstance, "_children"), service)
	rawget(gameInstance, "_props")[name] = service
end
rawget(gameInstance, "_props").Workspace = services.Workspace

Mock.game = gameInstance
Mock.workspace = services.Workspace
Mock.services = services

-- ============================================================================
-- task / os / global installation
-- ============================================================================

Mock.task = {
	spawn = function(fn, ...)
		local thread = type(fn) == "thread" and fn or coroutine.create(fn)
		local ok, err = coroutine.resume(thread, ...)
		if not ok then
			warn("[task.spawn] " .. tostring(err))
		end
		return thread
	end,
	defer = function(fn, ...)
		local thread = type(fn) == "thread" and fn or coroutine.create(fn)
		Scheduler.schedule(0, thread, table.pack(...))
		return thread
	end,
	delay = function(seconds, fn, ...)
		local thread = type(fn) == "thread" and fn or coroutine.create(fn)
		Scheduler.schedule(seconds, thread, table.pack(...))
		return thread
	end,
	wait = function(seconds)
		local thread = coroutine.running()
		Scheduler.schedule(seconds or 0, thread, {})
		coroutine.yield()
		return seconds or 0
	end,
	cancel = function(thread)
		for _, entry in ipairs(Scheduler.queue) do
			if entry.thread == thread then
				entry.cancelled = true
			end
		end
	end,
	synchronize = function() end,
	desynchronize = function() end,
}

--[[
	Installs the mock into the global environment. Call once before requiring any
	game module. Returns the mock table for convenience.
]]
function Mock.install()
	-- `_G` is a frozen table in the standalone Luau CLI, but `getfenv(0)` yields the
	-- writable globals table that free variables in every required module resolve
	-- against. Roblox scripts read `Instance`, `game`, `task` and friends as free
	-- globals, so this is how we make the mock visible to them.
	local g = getfenv(0)
	Mock.globals = g
	local function setGlobal(name, value)
		g[name] = value
	end

	setGlobal("Instance", Mock.Instance)
	setGlobal("Vector3", Mock.Vector3)
	setGlobal("Vector2", Mock.Vector2)
	setGlobal("CFrame", Mock.CFrame)
	setGlobal("Color3", Mock.Color3)
	setGlobal("UDim", Mock.UDim)
	setGlobal("UDim2", Mock.UDim2)
	setGlobal("Enum", Mock.Enum)
	setGlobal("NumberRange", Mock.NumberRange)
	setGlobal("NumberSequence", Mock.NumberSequence)
	setGlobal("NumberSequenceKeypoint", Mock.NumberSequenceKeypoint)
	setGlobal("ColorSequence", Mock.ColorSequence)
	setGlobal("ColorSequenceKeypoint", Mock.ColorSequenceKeypoint)
	setGlobal("TweenInfo", Mock.TweenInfo)
	setGlobal("Rect", Mock.Rect)
	setGlobal("Region3", Mock.Region3)
	setGlobal("Ray", Mock.Ray)
	setGlobal("game", Mock.game)
	setGlobal("workspace", Mock.workspace)
	setGlobal("task", Mock.task)
	setGlobal("tick", function()
		return Scheduler.now
	end)
	setGlobal("time", function()
		return Scheduler.now
	end)
	setGlobal("elapsedTime", function()
		return Scheduler.now
	end)
	setGlobal("typeof", function(value)
		local mt = getmetatable(value)
		if mt == Vector3Mt then
			return "Vector3"
		elseif mt == Vector2Mt then
			return "Vector2"
		elseif mt == CFrameMt then
			return "CFrame"
		elseif mt == Color3Mt then
			return "Color3"
		elseif mt == UDim2Mt then
			return "UDim2"
		elseif mt == UDimMt then
			return "UDim"
		elseif mt == InstanceMt then
			return "Instance"
		elseif mt == MockSignal then
			return "RBXScriptSignal"
		end
		return type(value)
	end)
	-- Roblox globals that the standalone CLI does not provide.
	setGlobal("warn", function(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[i] = tostring((select(i, ...)))
		end
		if Mock.captureWarnings then
			table.insert(Mock.warnings, table.concat(parts, " "))
		elseif not Mock.silenceWarnings then
			print("\27[33m[warn]\27[0m " .. table.concat(parts, " "))
		end
	end)
	setGlobal("DebuggerManager", function()
		return { AddDebugger = function() end }
	end)
	setGlobal("settings", function()
		return { Physics = {}, Rendering = {}, Network = {} }
	end)
	setGlobal("UserSettings", function()
		return { GetService = function() return { GetAsync = function() end } end }
	end)
	setGlobal("Random", {
		new = function(seed)
			local state = seed or 12345
			local api = {}
			function api:NextNumber(min, max)
				state = (state * 1103515245 + 12345) % 2147483648
				local v = state / 2147483648
				if min and max then
					return min + (max - min) * v
				end
				return v
			end
			function api:NextInteger(min, max)
				return math.floor(api:NextNumber() * (max - min + 1)) + min
			end
			function api:NextUnitVector()
				return v3(0, 1, 0)
			end
			function api:Shuffle(t)
				for i = #t, 2, -1 do
					local j = api:NextInteger(1, i)
					t[i], t[j] = t[j], t[i]
				end
			end
			return api
		end,
	})
	return Mock
end

return Mock
