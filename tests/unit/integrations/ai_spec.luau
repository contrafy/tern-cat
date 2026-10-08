--!strict
local t = require("../../lib/test")
local factories = require("../../lib/factories")
local ai = require("../../../cat/integrations/ai")
local events = require("../../../cat/core/events")

local describe, it, expect = t.describe, t.it, t.expect

local HOUR = 3600
local DAY = 24 * HOUR

local function aiConfig(overrides: { [string]: any }?): any
	local ai_over: { [string]: any } = {
		enabled = true,
		provider = "mock",
		max_turns_per_hour = 2,
		max_turns_per_day = 10,
		cooldown_s = 300,
	}
	for k, v in overrides or {} do
		ai_over[k] = v
	end
	return factories.config({ ai = ai_over })
end

local function finished(category: string, status: number, took_ms: number): any
	return events.commandFinished({
		id = "ev-1",
		time = 1700000000,
		scope = "host",
		pane = 1,
		category = category :: any,
		status = status,
		took_ms = took_ms,
	})
end

local function ctx(now_s: number, config: any?): any
	return { now_s = now_s, config = config or aiConfig(), mood = "calm" }
end

local function recordAt(budget: any, times: { number }): any
	local b = budget
	for _, at in times do
		b = ai.record(b, at)
	end
	return b
end

describe("integrations.ai", function()
	describe("budget", function()
		it("blocks every request while AI is disabled, which is the default", function()
			local ok, reason = ai.canRequest(ai.newBudget(), 1000, aiConfig({ enabled = false }))
			expect(ok).toBeFalsy()
			expect(reason).toContain("disabled")
		end)

		it("allows the first request when enabled", function()
			local ok = ai.canRequest(ai.newBudget(), 1000, aiConfig())
			expect(ok).toBeTruthy()
		end)

		it("enforces the cooldown between turns", function()
			local b = recordAt(ai.newBudget(), { 1000 })
			local ok, reason = ai.canRequest(b, 1000 + 299, aiConfig())
			expect(ok).toBeFalsy()
			expect(reason).toContain("cooldown")
			expect((ai.canRequest(b, 1000 + 300, aiConfig()))).toBeTruthy()
		end)

		it("caps turns per hour", function()
			local config = aiConfig({ cooldown_s = 60 })
			local b = recordAt(ai.newBudget(), { 1000, 1060 })
			local ok, reason = ai.canRequest(b, 1120, config)
			expect(ok).toBeFalsy()
			expect(reason).toContain("hour")
			expect((ai.canRequest(b, 1000 + HOUR, config))).toBeTruthy()
		end)

		it("caps turns per day even when the hourly budget has room", function()
			local config = aiConfig({ cooldown_s = 60, max_turns_per_hour = 10, max_turns_per_day = 3 })
			local b = recordAt(ai.newBudget(), { 0, HOUR, 2 * HOUR })
			local ok, reason = ai.canRequest(b, 3 * HOUR, config)
			expect(ok).toBeFalsy()
			expect(reason).toContain("day")
			expect((ai.canRequest(b, DAY, config))).toBeTruthy()
		end)

		it("treats non-positive limits as no budget", function()
			local ok = ai.canRequest(ai.newBudget(), 0, aiConfig({ max_turns_per_hour = 0 }))
			expect(ok).toBeFalsy()
		end)

		it("does not mutate the budget it was given", function()
			local b = ai.newBudget()
			ai.record(b, 5)
			expect((ai.canRequest(b, 5, aiConfig()))).toBeTruthy()
		end)

		it("keeps history bounded under an event storm", function()
			local b = ai.newBudget()
			for i = 1, 5000 do
				b = ai.record(b, i)
			end
			expect(#b.history).toBeLessThanOrEqual(ai.MAX_HISTORY)
		end)
	end)

	describe("redact", function()
		it("summarizes a command event using only type, category, outcome and a coarse duration", function()
			local summary = ai.redact(finished("test", 1, 42000))
			expect(summary).toContain("test")
			expect(summary).toContain("failed")
			expect(summary).notToContain("42000")
		end)

		it("ignores smuggled attributes such as the command line or cwd", function()
			local ev = finished("network", 0, 10)
			ev.attributes.line = "curl -H 'Authorization: Bearer sk-live-123' https://x"
			ev.attributes.cwd = "/Users/me/secret-project"
			local summary = ai.redact(ev)
			expect(summary).notToContain("Bearer")
			expect(summary).notToContain("sk-live")
			expect(summary).notToContain("secret")
			expect(summary).notToContain("/")
		end)

		it("strips secret-like tokens, paths, URLs and env assignments from free text", function()
			local leaky = "export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG ghp_abcdefghijklmnop1234 "
				.. "cat ~/.ssh/id_rsa /etc/passwd C:\\Users\\me https://evil.example/x?token=abc "
				.. "user@example.com hunter2 correcthorsebatterystaple the cat napped"
			local summary = ai.redact(leaky)
			for _, needle in
				{
					"AWS",
					"wJalr",
					"ghp_",
					"ssh",
					"id_rsa",
					"passwd",
					"Users",
					"evil",
					"token",
					"example",
					"hunter2",
					"correcthorse",
					"/",
					"\\",
					"=",
					"@",
				}
			do
				expect(summary).notToContain(needle)
			end
			expect(summary).toContain("the cat napped")
		end)

		it("bounds summary length", function()
			local summary = ai.redact(string.rep("word ", 500))
			expect(#summary).toBeLessThanOrEqual(ai.MAX_SUMMARY)
		end)

		it("returns a neutral summary for unsupported input", function()
			expect(type(ai.redact(42 :: any))).toBe("string")
		end)
	end)

	describe("validateSuggestion", function()
		local allowed = { "happy", "blink", "look" }

		it("accepts a well-formed suggestion", function()
			local s, err = ai.validateSuggestion({ animation = "happy", text = "Nice build!" }, allowed :: any)
			expect(err).toBeNil()
			expect(s).toEqual({ animation = "happy", text = "Nice build!" })
		end)

		it("rejects malformed provider responses", function()
			local bad: { any } = {
				nil,
				"happy",
				42,
				{},
				{ animation = 1 },
				{ animation = "moonwalk" },
				{ animation = "swat" },
				{ animation = "happy", text = 5 },
				{ animation = "happy", run_command = "rm -rf ~" },
				{ animation = "happy", text = string.rep("a", 81) },
				{ animation = "happy", text = "line\nbreak" },
				{ animation = "happy", text = "bell\7" },
				{ animation = "happy", text = "see https://x.y" },
				{ animation = "happy", text = "visit www.cats" },
				{ animation = "happy", text = "go to evil.com now" },
				{ animation = "happy", text = "caf\195\169" },
			}
			for i = 1, 16 do
				local s, err = ai.validateSuggestion(bad[i], allowed :: any)
				if s ~= nil then
					error(`case {i} should have been rejected`)
				end
				expect(type(err)).toBe("string")
			end
		end)

		it("treats empty text as no text", function()
			local s = ai.validateSuggestion({ animation = "blink", text = "   " }, allowed :: any)
			expect(s).toEqual({ animation = "blink" })
		end)
	end)

	describe("providers", function()
		it("disables the Carly schedule adapter with an explanation", function()
			local p = ai.carlyScheduleProvider()
			expect(p.id).toBe("carly_schedule")
			expect(p.available).toBe(false)
			expect(p.unavailable_reason).toContain("0.6.2")
			expect(p.unavailable_reason).toContain("tool access")
			local gotErr: string? = nil
			p:request({ summary = "x", mood = "calm", allowed_animations = {} }, function(_, err)
				gotErr = err
			end)
			expect(gotErr).notToBeNil()
		end)

		it("offers a none provider that never answers", function()
			local p = ai.noneProvider()
			expect(p.id).toBe("none")
			expect(p.available).toBe(false)
		end)

		it("replays mock responses in order and records the requests it saw", function()
			local p = ai.mockProvider({ { suggestion = { animation = "happy" } }, { err = "boom" } })
			local results = {}
			local req = { summary = "s", mood = "calm", allowed_animations = { "happy" } }
			p:request(req :: any, function(s, err)
				table.insert(results, { s = s, err = err })
			end)
			p:request(req :: any, function(s, err)
				table.insert(results, { s = s, err = err })
			end)
			p:request(req :: any, function(s, err)
				table.insert(results, { s = s, err = err })
			end)
			expect(results[1].s).toEqual({ animation = "happy" })
			expect(results[2].err).toBe("boom")
			expect(results[3].err).notToBeNil()
			expect(#p.requests).toBe(3)
		end)
	end)

	describe("suggest", function()
		local function run(state: any, ev: any, c: any, provider: any): (any, any, any)
			local final, suggestion, reason
			local immediate = ai.suggest(state, ev, c, provider, function(s, sug, why)
				final, suggestion, reason = s, sug, why
			end)
			expect(immediate).notToBeNil()
			return final, suggestion, reason
		end

		it("applies a validated suggestion and records why for transparency", function()
			local p = ai.mockProvider({ { suggestion = { animation = "happy", text = "Purr." } } })
			local state, suggestion, reason = run(ai.newState(), finished("build", 0, 3000), ctx(1000), p)
			expect(suggestion).toEqual({ animation = "happy", text = "Purr." })
			expect(type(reason)).toBe("string")
			local last = ai.lastAiReaction(state)
			expect(last.outcome).toBe("applied")
			expect(last.animation).toBe("happy")
			expect(last.at).toBe(1000)
			expect(last.summary).toContain("build")
		end)

		it("sends only the redacted summary to the provider", function()
			local p = ai.mockProvider({ { suggestion = { animation = "blink" } } })
			local ev = finished("network", 0, 10)
			ev.attributes.line = "curl https://user:pass@host/secret"
			run(ai.newState(), ev, ctx(1000), p)
			local sent = t.render(p.requests[1])
			expect(sent).notToContain("pass")
			expect(sent).notToContain("secret")
			expect(sent).notToContain("curl")
		end)

		it("never calls the provider when disabled or over budget", function()
			local p = ai.mockProvider({})
			local _, suggestion, reason =
				run(ai.newState(), finished("test", 1, 1), ctx(0, aiConfig({ enabled = false })), p)
			expect(suggestion).toBeNil()
			expect(reason).toContain("disabled")
			expect(#p.requests).toBe(0)
		end)

		it("turns an event storm into at most the configured number of turns", function()
			local responses = {}
			for i = 1, 1000 do
				responses[i] = { suggestion = { animation = "blink" } }
			end
			local p = ai.mockProvider(responses)
			local state = ai.newState()
			for i = 1, 1000 do
				local final = run(state, finished("test", i % 2, 10), ctx(1000 + i / 1000), p)
				state = final
			end
			expect(#p.requests).toBe(1)
		end)

		it("counts a turn against the budget even if the provider fails", function()
			local p = ai.mockProvider({ { err = "network down" } })
			local state, suggestion = run(ai.newState(), finished("test", 1, 1), ctx(1000), p)
			expect(suggestion).toBeNil()
			expect(ai.lastAiReaction(state).outcome).toBe("error")
			expect((ai.canRequest(state.budget, 1001, aiConfig()))).toBeFalsy()
		end)

		it("rejects malformed provider output instead of acting on it", function()
			local p = ai.mockProvider({ { suggestion = { animation = "happy", send_input = "rm -rf /" } } })
			local state, suggestion = run(ai.newState(), finished("test", 0, 1), ctx(1000), p)
			expect(suggestion).toBeNil()
			expect(ai.lastAiReaction(state).outcome).toBe("rejected")
		end)

		it("does not consult unavailable providers or spend budget on them", function()
			local state, suggestion, reason =
				run(ai.newState(), finished("test", 0, 1), ctx(1000), ai.carlyScheduleProvider())
			expect(suggestion).toBeNil()
			expect(reason).toContain("tool access")
			expect((ai.canRequest(state.budget, 1000, aiConfig()))).toBeTruthy()
		end)

		it("survives providers that throw or answer twice", function()
			local thrower: any = {
				id = "mock",
				available = true,
				request = function()
					error("kaboom")
				end,
			}
			local state, suggestion = run(ai.newState(), finished("test", 0, 1), ctx(1000), thrower)
			expect(suggestion).toBeNil()
			expect(ai.lastAiReaction(state).outcome).toBe("error")

			local calls = 0
			local double: any = {
				id = "mock",
				available = true,
				request = function(_, _, done)
					done({ animation = "happy" }, nil)
					done({ animation = "look" }, nil)
				end,
			}
			ai.suggest(ai.newState(), finished("test", 0, 1), ctx(1000), double, function()
				calls += 1
			end)
			expect(calls).toBe(1)
		end)

		it("ignores high-frequency event types entirely", function()
			local p = ai.mockProvider({ { suggestion = { animation = "happy" } } })
			local ev = { event_id = "p", time = 0, type = "pointer", scope = "window", attributes = {} }
			local _, suggestion = run(ai.newState(), ev, ctx(1000), p)
			expect(suggestion).toBeNil()
			expect(#p.requests).toBe(0)
		end)

		it("can be cleared", function()
			local p = ai.mockProvider({ { suggestion = { animation = "happy" } } })
			run(ai.newState(), finished("test", 0, 1), ctx(1000), p)
			expect(ai.lastAiReaction(ai.newState())).toBeNil()
		end)
	end)
end)
