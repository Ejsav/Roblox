--!strict
--[[
	Validate
	--------
	Argument validation for anything crossing the client/server boundary.

	Every remote declares a schema; this module turns that schema into a check that
	runs before a handler ever sees the payload. A malformed or hostile packet is
	rejected at the edge with a named reason, which the anti-cheat layer then counts.

	The checkers are deliberately strict about types AND ranges. A client that can
	send `capture(stormId, -1e308)` should be rejected by the schema, not by a
	defensive branch buried three services deep.
]]

local Validate = {}

export type Checker = (value: any) -> (boolean, string?)

--[[ Any value at all, including nil. Use sparingly and never for a value with reach. ]]
function Validate.Any(): Checker
	return function()
		return true, nil
	end
end

function Validate.String(minLength: number?, maxLength: number?): Checker
	local min = minLength or 0
	local max = maxLength or 256
	return function(value)
		if type(value) ~= "string" then
			return false, "expected string"
		end
		if #value < min then
			return false, ("string shorter than %d"):format(min)
		end
		if #value > max then
			return false, ("string longer than %d"):format(max)
		end
		return true, nil
	end
end

--[[ A string restricted to an allow-list — the safest way to accept an id. ]]
function Validate.Enum(allowed: { [string]: any } | { string }): Checker
	local lookup: { [string]: boolean } = {}
	if #(allowed :: any) > 0 and type((allowed :: any)[1]) == "string" then
		for _, key in ipairs(allowed :: { string }) do
			lookup[key] = true
		end
	else
		for key in pairs(allowed :: { [string]: any }) do
			lookup[key] = true
		end
	end
	return function(value)
		if type(value) ~= "string" then
			return false, "expected string"
		end
		if not lookup[value] then
			return false, "value not in allowed set"
		end
		return true, nil
	end
end

function Validate.Number(min: number?, max: number?): Checker
	local lower = min or -math.huge
	local upper = max or math.huge
	return function(value)
		if type(value) ~= "number" then
			return false, "expected number"
		end
		-- NaN fails every comparison, so it must be caught explicitly.
		if value ~= value then
			return false, "NaN"
		end
		if value == math.huge or value == -math.huge then
			return false, "infinite"
		end
		if value < lower or value > upper then
			return false, ("outside range [%s, %s]"):format(tostring(lower), tostring(upper))
		end
		return true, nil
	end
end

function Validate.Integer(min: number?, max: number?): Checker
	local numberCheck = Validate.Number(min, max)
	return function(value)
		local ok, reason = numberCheck(value)
		if not ok then
			return false, reason
		end
		if math.floor(value) ~= value then
			return false, "expected integer"
		end
		return true, nil
	end
end

function Validate.Boolean(): Checker
	return function(value)
		if type(value) ~= "boolean" then
			return false, "expected boolean"
		end
		return true, nil
	end
end

--[[ A Vector3 within sane world bounds. Rejects NaN and absurd coordinates. ]]
function Validate.Vector3(maxMagnitude: number?): Checker
	local limit = maxMagnitude or 60000
	return function(value)
		if typeof(value) ~= "Vector3" then
			return false, "expected Vector3"
		end
		local x, y, z = value.X, value.Y, value.Z
		if x ~= x or y ~= y or z ~= z then
			return false, "NaN component"
		end
		if math.abs(x) > limit or math.abs(y) > limit or math.abs(z) > limit then
			return false, "coordinate out of bounds"
		end
		return true, nil
	end
end

function Validate.Instance(className: string?): Checker
	return function(value)
		if typeof(value) ~= "Instance" then
			return false, "expected Instance"
		end
		if className and not value:IsA(className) then
			return false, "expected " .. className
		end
		return true, nil
	end
end

--[[ An array whose every element passes `elementChecker`. Depth and size bounded. ]]
function Validate.Array(elementChecker: Checker, maxLength: number?): Checker
	local limit = maxLength or 64
	return function(value)
		if type(value) ~= "table" then
			return false, "expected table"
		end
		local count = 0
		for key, element in pairs(value) do
			if type(key) ~= "number" then
				return false, "expected array, found non-numeric key"
			end
			count += 1
			if count > limit then
				return false, ("array longer than %d"):format(limit)
			end
			local ok, reason = elementChecker(element)
			if not ok then
				return false, ("element %d: %s"):format(count, reason or "invalid")
			end
		end
		return true, nil
	end
end

--[[
	A dictionary with a fixed shape. Unlisted keys are rejected outright rather than
	ignored, so a client cannot smuggle extra fields past a permissive handler.
]]
function Validate.Shape(shape: { [string]: Checker }, optionalKeys: { [string]: boolean }?): Checker
	return function(value)
		if type(value) ~= "table" then
			return false, "expected table"
		end
		for key in pairs(value) do
			if shape[key] == nil then
				return false, ("unexpected key '%s'"):format(tostring(key))
			end
		end
		for key, checker in pairs(shape) do
			local fieldValue = value[key]
			if fieldValue == nil then
				if not (optionalKeys and optionalKeys[key]) then
					return false, ("missing key '%s'"):format(key)
				end
			else
				local ok, reason = checker(fieldValue)
				if not ok then
					return false, ("key '%s': %s"):format(key, reason or "invalid")
				end
			end
		end
		return true, nil
	end
end

--[[ Allows nil in addition to whatever the wrapped checker accepts. ]]
function Validate.Optional(checker: Checker): Checker
	return function(value)
		if value == nil then
			return true, nil
		end
		return checker(value)
	end
end

--[[ Passes when any of the supplied checkers passes. ]]
function Validate.OneOf(...: Checker): Checker
	local checkers = { ... }
	return function(value)
		for _, checker in ipairs(checkers) do
			if checker(value) then
				return true, nil
			end
		end
		return false, "matched none of the accepted types"
	end
end

--[[
	Runs a list of checkers against a list of arguments.
	Returns (ok, argumentIndex, reason) so the caller can log precisely what failed.
]]
function Validate.Arguments(checkers: { Checker }, args: { any }, argCount: number): (boolean, number?, string?)
	if argCount > #checkers then
		return false, #checkers + 1, "too many arguments"
	end
	for index, checker in ipairs(checkers) do
		local ok, reason = checker(args[index])
		if not ok then
			return false, index, reason
		end
	end
	return true, nil, nil
end

--[[
	Sanitises a string for display: strips control characters and clamps length.
	Applied to anything player-authored that another player will see.
]]
function Validate.SanitiseText(text: string, maxLength: number?): string
	local cleaned = text:gsub("[%c]", "")
	local limit = maxLength or 128
	if #cleaned > limit then
		cleaned = cleaned:sub(1, limit)
	end
	return cleaned
end

return Validate
