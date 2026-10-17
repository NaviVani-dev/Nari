__nari_permissions = nil
local timers = {}
local resolvers = {}
local register = __nari_register_resolver
__nari_register_resolver = nil

function nari.resolver(scheme, handler)
	resolvers[scheme] = handler
	register(scheme)
end

function __nari_resolve(scheme, id)
	local handler = resolvers[scheme]
	if not handler then
		return nil, "no resolver for " .. scheme
	end
	local ok, url = __nari_call(handler, id)
	if not ok then
		return nil, url.message
	end
	return url
end
local sources = {}
local register_source = __nari_register_source
__nari_register_source = nil

function nari.source(scheme, handler, options)
	sources[scheme] = handler
	local save = options and options.save
	register_source(scheme, save == false and "deny" or save == "sealed" and "sealed" or "allow")
end

function __nari_source(scheme, id, out)
	local handler = sources[scheme]
	if not handler then
		return "no source for " .. scheme
	end
	local ok, problem = __nari_call(handler, id, out)
	if not ok then
		return problem.message
	end
end
local clock = __nari_clock
__nari_clock = nil

function nari.after(seconds, handler)
	table.insert(timers, { at = clock() + seconds, handler = handler })
end

function __nari_tick()
	local now = clock()
	local due = {}
	for index = #timers, 1, -1 do
		if timers[index].at <= now then
			table.insert(due, 1, table.remove(timers, index))
		end
	end
	table.sort(due, function(a, b) return a.at < b.at end)
	for _, timer in ipairs(due) do
		__nari_call(timer.handler)
	end
	local soonest
	for _, timer in ipairs(timers) do
		if not soonest or timer.at < soonest then
			soonest = timer.at
		end
	end
	return soonest and math.max(soonest - clock(), 0) or nil
end
local ask_thread = __nari_ask_thread
__nari_ask_thread = nil
local ask_handler
local on = nari.on

function nari.on(event, handler)
	if event == "ask" then
		ask_handler = handler
		return
	end
	on(event, handler)
end

function nari.ask(name, value, timeout)
	return ask_thread(name, value, timeout)
end

function __nari_ask(value, reply)
	if not ask_handler then
		return reply(nil, "the thread doesn't answer questions")
	end
	local ok, answer = __nari_call(ask_handler, value, reply)
	if not ok then
		reply(nil, answer.message)
	elseif answer ~= nil then
		reply(answer)
	end
end

local start_server, stop_server = __nari_serve_start, __nari_serve_stop
__nari_serve_start, __nari_serve_stop = nil, nil

function nari.serve(handler, options)
	local key, port = start_server(handler, options and options.port)
	return {
		port = port,
		url = "http://127.0.0.1:" .. port,
		stop = function()
			stop_server(key)
		end,
	}
end

local sockets = {}
local connect = __nari_tcp
__nari_tcp = nil

function nari.tcp(spec)
	local raw, problem = connect(spec)
	if not raw then
		return nil, problem
	end
	local id = raw:id()
	local socket = { handlers = {} }
	function socket:send(bytes)
		return raw:send(bytes)
	end
	function socket:receive(count, timeout)
		return raw:receive(count, timeout)
	end
	function socket:on_data(handler)
		self.handlers.data = handler
		sockets[id] = self
		raw:listen()
	end
	function socket:on_close(handler)
		self.handlers.close = handler
		sockets[id] = self
	end
	function socket:close()
		sockets[id] = nil
		raw:close()
	end
	return socket
end

function __nari_socket(id, bytes)
	local socket = sockets[id]
	if socket and socket.handlers.data then
		__nari_call(socket.handlers.data, bytes)
	end
end

function __nari_socket_closed(id, problem)
	local socket = sockets[id]
	sockets[id] = nil
	if socket and socket.handlers.close then
		__nari_call(socket.handlers.close, problem)
	end
end
