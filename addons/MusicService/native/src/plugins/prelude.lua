local plugin = __nari_plugin
__nari_plugin = nil
local permissions = __nari_permissions
__nari_permissions = nil
local OS, Main, MediaPlayer, Plugins, Dialog = OS, Main, MediaPlayer, Plugins, Dialog

local function need(permission, what)
	if not permissions[permission] then
		error(what .. ' needs the "' .. permission .. '" permission: add it to "permissions" in manifest.json', 3)
	end
end
local start_thread, send_thread, stop_thread = nari.__thread_start, nari.__thread_send, nari.__thread_stop
nari.__thread_start, nari.__thread_send, nari.__thread_stop = nil, nil, nil
local start_server, stop_server = nari.__serve_start, nari.__serve_stop
nari.__serve_start, nari.__serve_stop = nil, nil

local threads = {}
local playing

function __nari_log(level, text)
	plugin:write_log(level, text)
end

function nari.log_color(color)
	plugin:set_log_color(color)
end

function nari.webview(spec)
	need("network", "nari.webview()")
	local view = plugin:open_webview(spec)
	if not view then
		return nil
	end
	local web, results = { view = view }, {}
	local function forward(signal, name)
		if spec[name] then
			view[signal]:connect(function(...) spec[name](web, ...) end)
		end
	end
	forward("page_load_started", "on_start")
	forward("page_load_finished", "on_load")
	forward("ipc_message", "on_message")
	forward("title_changed", "on_title")
	forward("tree_exiting", "on_close")
	view.script_result:connect(function(id, result)
		local done = results[id]
		results[id] = nil
		if done then
			done(result)
		end
	end)
	function web:load(url)
		view.url = url
	end
	function web:eval(script, done)
		results[view:eval(script)] = done
	end
	function web:cookies(url)
		return view:get_cookies(url)
	end
	function web:close()
		plugin:close_webview(view)
	end
	return web
end

if plugin:is_theme() then
	local info = plugin:theme_info()
	nari.theme = {
		id = info.id,
		path = info.path,
		folder = info.folder,
		apply = function(overrides) plugin:theme_apply(Dictionary(overrides or {})) end,
		settings = function(list) plugin:theme_settings(list or {}) end,
		setting = function(key) return plugin:theme_setting(key) end,
		page = function() return plugin:theme_page() end,
	}
end

function nari.is_ready()
	return Plugins:is_nari_ready()
end

function nari.path(file)
	return plugin:path_of(file)
end

function nari.load(file)
	return plugin:load_relative(file)
end

function nari.after(seconds, handler)
	Main:get_tree():create_timer(seconds).timeout:connect(handler)
end

function nari.await(value, handler)
	if __nari_is_object(value) and value:get_class() == "GDScriptFunctionState" then
		value.completed:connect(handler)
	else
		handler(value)
	end
end

function nari.analyze(target, options, handler)
	if type(options) == "function" then
		options, handler = nil, options
	end
	nari.await(MediaPlayer:analyze(target, options or {}), function(result)
		if result.error then
			handler(nil, result.error)
		else
			handler(result)
		end
	end)
end

function nari.current()
	local song = MediaPlayer:get_current_song()
	if next(song) == nil then
		return nil
	end
	return song
end

function nari.lyrics_provider(spec)
	plugin:add_lyrics_provider(spec)
end

function nari.music_provider(spec)
	return plugin:add_music_provider(spec)
end

function nari.visualizer(spec)
	if type(spec) == "string" then
		spec = { shader = spec }
	end
	plugin:add_visualizer(spec)
end

function nari.output(spec)
	if type(spec) ~= "table" or type(spec.scan) ~= "function" or type(spec.connect) ~= "function" then
		error("nari.output() needs a table with scan and connect functions", 2)
	end
	local key = plugin:add_output(spec)
	local output = {}
	function output:release()
		plugin:release_output(key)
	end
	function output:is_connected()
		return plugin:output_connected(key)
	end
	return output
end

function nari.cover_view(spec)
	if type(spec) ~= "table" or not spec.icon then
		error("nari.cover_view() needs a table with an icon", 2)
	end
	local key = plugin:add_cover_view(spec)
	local view = {}
	function view:set_available(available)
		plugin:cover_view_available(key, available == true)
	end
	function view:set_texture(texture)
		plugin:cover_view_texture(key, texture)
	end
	function view:is_active()
		return plugin:cover_view_active(key)
	end
	return view
end

function nari.video(source, options)
	if type(source) ~= "string" or source == "" then
		error("nari.video() needs a file or an http(s) URL", 2)
	end
	if source:match("^https?://") then
		need("network", "nari.video() with a URL")
	end
	local id = plugin:open_video(source, options or {})
	if id < 0 then
		error("nari.video() can't open '" .. source .. "'", 2)
	end
	local video = {}
	function video:texture()
		return plugin:video_texture(id)
	end
	function video:play()
		plugin:video_playing(id, true)
	end
	function video:pause()
		plugin:video_playing(id, false)
	end
	function video:seek(seconds)
		plugin:video_seek(id, seconds)
	end
	function video:position()
		return plugin:video_position(id)
	end
	function video:length()
		return plugin:video_length(id)
	end
	function video:watch(item)
		plugin:video_watch(id, item)
	end
	function video:close()
		plugin:close_video(id)
	end
	return video
end

function nari.command(name, description, handler)
	if type(description) == "function" then
		handler, description = description, ""
	end
	if type(name) ~= "string" or type(handler) ~= "function" then
		error("nari.command(name, description, handler) needs a name and a function", 2)
	end
	if not plugin:add_command(name, description or "", handler) then
		error("can't add the command '" .. name .. "': another one has that name, or it has spaces", 2)
	end
end

function nari.discover_section(spec)
	if type(spec) ~= "table" or type(spec.title) ~= "string" or spec.items == nil then
		error("nari.discover_section() needs a table with a title and items", 2)
	end
	plugin:add_discover_section(spec)
end

function nari.item_action(spec)
	if type(spec) ~= "table" or type(spec.title) ~= "string" or type(spec.action) ~= "function" then
		error("nari.item_action() needs a table with a title and an action", 2)
	end
	spec.kinds = spec.kinds or { "track", "album", "artist", "playlist" }
	plugin:add_item_action(spec)
end

function nari.effect(spec)
	plugin:add_effect(spec)
end

local user_settings
local declared = {}
local SETTING_TYPES = { toggle = true, text = true, number = true, choice = true }

local function setting_value(spec)
	local value = nari.get(spec.key)
	if value == nil then
		return spec.default
	end
	return value
end

local function option_of(option)
	if type(option) == "table" then
		return option.value, option.label or tostring(option.value)
	end
	return option, tostring(option)
end

local function setting_text(spec)
	local value = setting_value(spec)
	if spec.type == "toggle" then
		return value and "On" or "Off"
	end
	if value == nil or value == "" then
		return "Not set"
	end
	if spec.private then
		return "••••"
	end
	if spec.type == "choice" then
		for _, option in ipairs(spec.options or {}) do
			local stored, label = option_of(option)
			if stored == value then
				return label
			end
		end
	end
	return tostring(value)
end

local function store_setting(spec, value)
	nari.set(spec.key, value, { private = spec.private == true })
	if spec.changed then
		spec.changed(value)
	end
	Plugins.plugins_changed:emit()
end

local function edit_setting(spec)
	if spec.type == "toggle" then
		store_setting(spec, not setting_value(spec))
	else
		local current = setting_value(spec)
		local shown = (spec.private or current == nil) and "" or tostring(current)
		Dialog.ask(spec.title, shown, spec.private == true, function(text)
			if spec.type == "number" then
				local number = tonumber(text)
				if number == nil then
					error("'" .. text .. "' isn't a number", 0)
				end
				store_setting(spec, number)
			else
				store_setting(spec, text)
			end
		end)
	end
end

local function setting_entries()
	local entries = {}
	for _, spec in ipairs(declared) do
		local entry = {
			title = spec.title,
			description = spec.description or "",
			icon = spec.icon,
			section = spec.section,
			value = function() return setting_text(spec) end,
			reset = function() store_setting(spec, nil) end,
		}
		if spec.type == "choice" then
			local options = {}
			for _, option in ipairs(spec.options or {}) do
				local stored, label = option_of(option)
				table.insert(options, { value = stored, label = label })
			end
			entry.choices = {
				options = options,
				get = function() return setting_value(spec) end,
				set = function(value) store_setting(spec, value) end,
			}
		else
			entry.action = function() edit_setting(spec) end
		end
		table.insert(entries, entry)
	end
	for _, entry in ipairs(user_settings and user_settings() or {}) do
		table.insert(entries, entry)
	end
	return entries
end

function nari.settings(builder)
	user_settings = builder
	plugin:set_settings(setting_entries)
end

function nari.setting(spec)
	if type(spec) ~= "table" or type(spec.key) ~= "string" or type(spec.title) ~= "string" then
		error("nari.setting() needs a table with a key and a title", 2)
	end
	spec.type = spec.type or "text"
	if not SETTING_TYPES[spec.type] then
		error("nari.setting(): type must be toggle, text, number or choice", 2)
	end
	local current = nari.get(spec.key)
	if spec.private and current ~= nil then
		nari.set(spec.key, current, { private = true })
	end
	table.insert(declared, spec)
	plugin:set_settings(setting_entries)
end

function nari.settings_entry(category, builder)
	plugin:add_settings_entry(category, builder)
end

function nari.home_entry(spec)
	plugin:add_home_entry(spec)
end

function nari.now_playing_tab(spec)
	plugin:add_now_playing_tab(spec)
end

function nari.open_url(url)
	need("network", "nari.open_url()")
	return OS:shell_open(url) == 0
end

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

function nari.thread(file, options)
	local handle = { index = start_thread(file, options and options.name), handlers = {}, failures = {} }
	function handle:send(value)
		send_thread(self.index, value)
	end
	function handle:on_message(handler)
		table.insert(self.handlers, handler)
	end
	function handle:on_error(handler)
		table.insert(self.failures, handler)
	end
	function handle:stop()
		stop_thread(self.index)
		threads[self.index] = nil
	end
	threads[handle.index] = handle
	return handle
end

local function run(list, ...)
	for _, handler in ipairs(list) do
		__nari_call(handler, ...)
	end
end

function __nari_thread_message(index, value)
	if threads[index] then
		run(threads[index].handlers, value)
	end
end

function __nari_thread_failed(index, problem)
	if threads[index] then
		run(threads[index].failures, problem)
	end
end

local function page_name(page)
	return Main.PAGE_SCENES[page]
end

MediaPlayer.current_song_changed:connect(function(song)
	__nari_emit("track", next(song) and song or nil)
end)

MediaPlayer.playback_changed:connect(function(state)
	if state.is_playing ~= playing then
		playing = state.is_playing
		__nari_emit("state", { playing = playing, position = state.position })
	end
end)

MediaPlayer.song_played:connect(function(song)
	__nari_emit("played", song)
end)

Main.page_changed:connect(function(page, data)
	__nari_emit("page", page_name(page), Main:get_page(), data)
end)

function __nari_started()
	local song = nari.current()
	if song then
		playing = MediaPlayer:is_playing()
		__nari_emit("track", song)
		__nari_emit("state", { playing = playing, position = MediaPlayer:get_position() })
	end
	local page = Main:get_page()
	if page then
		__nari_emit("page", page_name(Main.current_page), page, Main.current_data)
	end
end
