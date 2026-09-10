--!strict
--[[
	TableUtil
	---------
	Table helpers used by data persistence, config merging and network payload building.
	Everything here is pure: nothing mutates its inputs unless the name says so.
]]

local TableUtil = {}

--[[ Shallow copy. ]]
function TableUtil.Copy<K, V>(t: { [K]: V }): { [K]: V }
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

--[[
	Deep copy with cycle protection. Used when handing a player's saved profile to
	gameplay systems so mutation never touches the canonical stored table.
]]
function TableUtil.DeepCopy(t: any, _seen: { [any]: any }?): any
	if type(t) ~= "table" then
		return t
	end
	local seen = _seen or {}
	if seen[t] then
		return seen[t]
	end
	local out = {}
	seen[t] = out
	for k, v in pairs(t) do
		out[TableUtil.DeepCopy(k, seen)] = TableUtil.DeepCopy(v, seen)
	end
	return out
end

--[[
	Recursively fills missing keys in `target` from `template`, returning the number of
	keys that were added. This is the backbone of profile schema migration: new fields
	added to the default profile automatically appear on old saves.
]]
function TableUtil.Reconcile(target: { [any]: any }, template: { [any]: any }): number
	local added = 0
	for key, templateValue in pairs(template) do
		local current = target[key]
		if current == nil then
			target[key] = TableUtil.DeepCopy(templateValue)
			added += 1
		elseif type(templateValue) == "table" and type(current) == "table" then
			-- Only reconcile dictionary-shaped tables; arrays are player data and are
			-- left exactly as saved.
			if not TableUtil.IsArray(templateValue) then
				added += TableUtil.Reconcile(current, templateValue)
			end
		end
	end
	return added
end

--[[ Removes keys from `target` that do not exist in `template`. Returns removed count. ]]
function TableUtil.Prune(target: { [any]: any }, template: { [any]: any }, protectedKeys: { [any]: boolean }?): number
	local removed = 0
	for key, value in pairs(target) do
		if template[key] == nil and not (protectedKeys and protectedKeys[key]) then
			target[key] = nil
			removed += 1
		elseif type(value) == "table" and type(template[key]) == "table" and not TableUtil.IsArray(template[key]) then
			removed += TableUtil.Prune(value, template[key], protectedKeys)
		end
	end
	return removed
end

--[[ True when the table is a contiguous 1..n array (empty tables count as arrays). ]]
function TableUtil.IsArray(t: { [any]: any }): boolean
	local n = 0
	for _ in pairs(t) do
		n += 1
	end
	return n == #t
end

function TableUtil.Count(t: { [any]: any }): number
	local n = 0
	for _ in pairs(t) do
		n += 1
	end
	return n
end

function TableUtil.IsEmpty(t: { [any]: any }): boolean
	return next(t) == nil
end

function TableUtil.Keys<K, V>(t: { [K]: V }): { K }
	local out = {}
	for k in pairs(t) do
		table.insert(out, k)
	end
	return out
end

function TableUtil.Values<K, V>(t: { [K]: V }): { V }
	local out = {}
	for _, v in pairs(t) do
		table.insert(out, v)
	end
	return out
end

function TableUtil.Map<K, V, R>(t: { [K]: V }, fn: (V, K) -> R): { [K]: R }
	local out = {}
	for k, v in pairs(t) do
		out[k] = fn(v, k)
	end
	return out
end

function TableUtil.Filter<V>(t: { V }, predicate: (V, number) -> boolean): { V }
	local out = {}
	for i, v in ipairs(t) do
		if predicate(v, i) then
			table.insert(out, v)
		end
	end
	return out
end

function TableUtil.Find<V>(t: { V }, predicate: (V, number) -> boolean): (V?, number?)
	for i, v in ipairs(t) do
		if predicate(v, i) then
			return v, i
		end
	end
	return nil, nil
end

function TableUtil.IndexOf<V>(t: { V }, value: V): number?
	for i, v in ipairs(t) do
		if v == value then
			return i
		end
	end
	return nil
end

function TableUtil.Contains<V>(t: { V }, value: V): boolean
	return TableUtil.IndexOf(t, value) ~= nil
end

--[[ Removes the first matching value with an unordered swap-remove (O(1)). ]]
function TableUtil.SwapRemove<V>(t: { V }, value: V): boolean
	local index = TableUtil.IndexOf(t, value)
	if not index then
		return false
	end
	local n = #t
	t[index] = t[n]
	t[n] = nil
	return true
end

function TableUtil.SwapRemoveIndex<V>(t: { V }, index: number): V?
	local n = #t
	if index < 1 or index > n then
		return nil
	end
	local value = t[index]
	t[index] = t[n]
	t[n] = nil
	return value
end

function TableUtil.Reduce<V, A>(t: { V }, fn: (A, V, number) -> A, initial: A): A
	local acc = initial
	for i, v in ipairs(t) do
		acc = fn(acc, v, i)
	end
	return acc
end

function TableUtil.Sum(t: { number }): number
	local total = 0
	for _, v in ipairs(t) do
		total += v
	end
	return total
end

function TableUtil.Append<V>(target: { V }, source: { V }): { V }
	local base = #target
	for i, v in ipairs(source) do
		target[base + i] = v
	end
	return target
end

function TableUtil.Concat<V>(a: { V }, b: { V }): { V }
	local out = table.create(#a + #b)
	table.move(a, 1, #a, 1, out)
	table.move(b, 1, #b, #a + 1, out)
	return out
end

--[[ Returns a new array with duplicates removed, preserving first-seen order. ]]
function TableUtil.Unique<V>(t: { V }): { V }
	local seen = {}
	local out = {}
	for _, v in ipairs(t) do
		if not seen[v] then
			seen[v] = true
			table.insert(out, v)
		end
	end
	return out
end

--[[ Converts an array into a lookup set. ]]
function TableUtil.ToSet<V>(t: { V }): { [V]: boolean }
	local out = {}
	for _, v in ipairs(t) do
		out[v] = true
	end
	return out
end

--[[ Stable sort by a numeric key extractor (descending when `descending` is true). ]]
function TableUtil.SortBy<V>(t: { V }, keyFn: (V) -> number, descending: boolean?): { V }
	local decorated = table.create(#t)
	for i, v in ipairs(t) do
		decorated[i] = { key = keyFn(v), index = i, value = v }
	end
	table.sort(decorated, function(a, b)
		if a.key == b.key then
			return a.index < b.index
		end
		if descending then
			return a.key > b.key
		end
		return a.key < b.key
	end)
	local out = table.create(#t)
	for i, entry in ipairs(decorated) do
		out[i] = entry.value
	end
	return out
end

--[[ Deep equality comparison, used by tests and by dirty-checking replicated state. ]]
function TableUtil.DeepEquals(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in pairs(a) do
		if not TableUtil.DeepEquals(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

--[[
	Produces a minimal diff between two dictionaries suitable for delta replication.
	Keys removed in `new` are represented by the sentinel returned from TableUtil.None().
]]
local NONE = newproxy(false)

function TableUtil.None(): any
	return NONE
end

function TableUtil.Diff(old: { [any]: any }, new: { [any]: any }): ({ [any]: any }, boolean)
	local diff = {}
	local changed = false
	for key, newValue in pairs(new) do
		local oldValue = old[key]
		if type(newValue) == "table" and type(oldValue) == "table" then
			local subDiff, subChanged = TableUtil.Diff(oldValue, newValue)
			if subChanged then
				diff[key] = subDiff
				changed = true
			end
		elseif oldValue ~= newValue then
			diff[key] = newValue
			changed = true
		end
	end
	for key in pairs(old) do
		if new[key] == nil then
			diff[key] = NONE
			changed = true
		end
	end
	return diff, changed
end

--[[ Applies a diff produced by TableUtil.Diff onto a target table in place. ]]
function TableUtil.ApplyDiff(target: { [any]: any }, diff: { [any]: any })
	for key, value in pairs(diff) do
		if value == NONE then
			target[key] = nil
		elseif type(value) == "table" and type(target[key]) == "table" then
			TableUtil.ApplyDiff(target[key], value)
		elseif type(value) == "table" then
			target[key] = TableUtil.DeepCopy(value)
		else
			target[key] = value
		end
	end
end

--[[ Recursively freezes a table. Config modules use this to guarantee immutability. ]]
function TableUtil.DeepFreeze<T>(t: T): T
	if type(t) ~= "table" then
		return t
	end
	for _, v in pairs(t :: any) do
		if type(v) == "table" and not table.isfrozen(v) then
			TableUtil.DeepFreeze(v)
		end
	end
	if not table.isfrozen(t :: any) then
		table.freeze(t :: any)
	end
	return t
end

return TableUtil
