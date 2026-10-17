local handlers = {}
local folder = nari.plugin.folder

local function write(level, ...)
	local parts = table.pack(...)
	for index = 1, parts.n do
		parts[index] = tostring(parts[index])
	end
	__nari_log(level, table.concat(parts, " ", 1, parts.n))
end

function nari.log(...)
	write("log", ...)
end

function nari.warn(...)
	write("warn", ...)
end

print = nari.log

os.exit = function()
	error("os.exit() is not available to plugins", 2) -- yeah bc why would it be
end

table.insert(package.searchers, 2, function(name)
	local file = name:gsub("%.", "/") .. ".lua"
	local handle = io.open(folder .. "/" .. file, "rb")
	if not handle then
		return "\n\tno file '" .. file .. "'"
	end
	local source = handle:read("a")
	handle:close()
	local chunk, problem = load(source, "@" .. file)
	if not chunk then
		error(problem, 0)
	end
	return chunk, file
end)

local function catch(problem)
	return { message = tostring(problem), trace = __nari_traceback() }
end

function __nari_call(handler, ...)
	local ok, problem = xpcall(handler, catch, ...)
	if not ok then
		__nari_report(problem.message, problem.trace)
	end
	return ok, problem
end

function nari.on(event, handler)
	handlers[event] = handlers[event] or {}
	table.insert(handlers[event], handler)
end

function __nari_emit(event, ...)
	for _, handler in ipairs(handlers[event] or {}) do
		__nari_call(handler, ...)
	end
end
