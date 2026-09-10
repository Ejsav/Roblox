--!strict
--[[
	RateLimiter
	-----------
	Token-bucket rate limiting, keyed per player per remote.

	Chosen over a fixed window because gameplay traffic is bursty by nature: a player
	clearing a seven-node Chain Web legitimately fires seven capture attempts in two
	seconds, then nothing for a minute. A fixed window either rejects that burst or is
	so loose it stops limiting anything. A bucket handles both.

	Buckets are created lazily and swept periodically so a busy server does not
	accumulate a table entry for every remote every player has ever touched.
]]

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type Budget = {
	budget: number,
	refill: number,
}

function RateLimiter.new()
	return setmetatable({
		-- buckets[playerKey][remoteName] = { tokens, lastRefill, budget, refill }
		_buckets = {},
		_lastSweep = 0,
	}, RateLimiter)
end

--[[
	Consumes one token for (playerKey, remoteName).
	Returns (allowed, tokensRemaining). A denied call consumes nothing, so a client
	being throttled cannot dig itself deeper by retrying.
]]
function RateLimiter:Consume(playerKey: any, remoteName: string, budget: Budget, now: number): (boolean, number)
	local playerBuckets = self._buckets[playerKey]
	if not playerBuckets then
		playerBuckets = {}
		self._buckets[playerKey] = playerBuckets
	end

	local bucket = playerBuckets[remoteName]
	if not bucket then
		bucket = {
			tokens = budget.budget,
			lastRefill = now,
			budget = budget.budget,
			refill = budget.refill,
		}
		playerBuckets[remoteName] = bucket
	end

	-- Refill proportionally to elapsed time, capped at the bucket's ceiling.
	local elapsed = now - bucket.lastRefill
	if elapsed > 0 then
		bucket.tokens = math.min(bucket.budget, bucket.tokens + elapsed * bucket.refill)
		bucket.lastRefill = now
	end

	if bucket.tokens < 1 then
		return false, bucket.tokens
	end

	bucket.tokens -= 1
	return true, bucket.tokens
end

--[[ Peeks at remaining tokens without consuming. ]]
function RateLimiter:Peek(playerKey: any, remoteName: string): number
	local playerBuckets = self._buckets[playerKey]
	if not playerBuckets then
		return math.huge
	end
	local bucket = playerBuckets[remoteName]
	return bucket and bucket.tokens or math.huge
end

--[[ Drops every bucket for a player. Called when they leave. ]]
function RateLimiter:Clear(playerKey: any)
	self._buckets[playerKey] = nil
end

--[[
	Removes buckets that are full and untouched for a while — they are indistinguishable
	from a fresh bucket, so keeping them costs memory and buys nothing.
]]
function RateLimiter:Sweep(now: number, idleSeconds: number?)
	local idle = idleSeconds or 120
	for playerKey, playerBuckets in pairs(self._buckets) do
		local any = false
		for remoteName, bucket in pairs(playerBuckets) do
			-- Apply the refill the bucket is owed before judging whether it is full;
			-- otherwise a long-idle bucket looks partially drained forever and is
			-- never collected.
			local projected = math.min(bucket.budget, bucket.tokens + (now - bucket.lastRefill) * bucket.refill)
			if now - bucket.lastRefill > idle and projected >= bucket.budget then
				playerBuckets[remoteName] = nil
			else
				any = true
			end
		end
		if not any then
			self._buckets[playerKey] = nil
		end
	end
	self._lastSweep = now
end

--[[ Diagnostic: how many buckets exist right now. ]]
function RateLimiter:GetBucketCount(): number
	local count = 0
	for _, playerBuckets in pairs(self._buckets) do
		for _ in pairs(playerBuckets) do
			count += 1
		end
	end
	return count
end

return RateLimiter
