local MARGIN, RADIUS, ROWS, HEAD = 12, 14, 5, 60
local CLEAR, SOLID = Color(1, 1, 1, 0), Color(1, 1, 1, 1)

local function clock(milliseconds)
	local seconds = math.max(0, math.floor(milliseconds / 1000))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

nari.on("skin", function(skin)
	local frames, tops, shown, toggles, rows, fits = {}, {}, {}, {}, {}, {}
	local scroll, idle, queue_mark, popup_open = 0, 0, nil, false
	local dots = ThemeEngine.dark_mode and 0.07 or 0.25
	local reveal

	local function light(item, on)
		item.accent = on
		skin:animate(item.glow, { modulate = on and SOLID or CLEAR }, 0.2)
		skin:animate(item.icon, { modulate = on and "AccentFg" or "PanelFg" }, 0.2)
	end

	local function button(parent, icon, x, y, size, action, tooltip, accent)
		local holder = skin:add(parent, { x = x, y = y, width = size, height = size, pivot = "center" })
		local radius = math.floor(size * 0.22)
		skin:add(holder, { type = "panel", width = size, height = size, radius = radius, color = "PanelBg" })
		local item = {
			accent = accent,
			glow = skin:add(holder, { type = "panel", width = size, height = size, radius = radius, color = "AccentBg", alpha = accent and 1 or 0 }),
			shine = skin:add(holder, { type = "panel", width = size, height = size, radius = radius, color = "PanelFg@0.1", alpha = 0 }),
			icon = skin:add(holder, { type = "image", image = "icons/" .. icon .. ".svg", x = size * 0.22, y = size * 0.22, width = size * 0.56, height = size * 0.56, modulate = accent and "AccentFg" or "PanelFg" }),
		}
		local press = skin:add(holder, {
			type = "button", width = size, height = size, tooltip = tooltip, sound = "ui:sub_select",
			command = type(action) == "string" and action or nil, on_click = type(action) == "function" and action or nil,
		})
		press.mouse_entered:connect(function()
			skin:animate(holder, { scale = 1.06 }, 0.15, { trans = "cubic", ease = "out" })
			skin:animate(item.shine, { modulate = SOLID }, 0.15)
		end)
		press.mouse_exited:connect(function()
			skin:animate(holder, { scale = 1 }, 0.2, { trans = "cubic", ease = "out" })
			skin:animate(item.shine, { modulate = CLEAR }, 0.2)
		end)
		press.button_down:connect(function() skin:animate(holder, { scale = 0.92 }, 0.08) end)
		press.button_up:connect(function() skin:animate(holder, { scale = 1.06 }, 0.2, { trans = "back", ease = "out" }) end)
		item.press, item.holder = press, holder
		return item
	end

	local function text(parent, x, y, width, height, size, weight, color, align)
		return skin:add(parent, { type = "text", x = x, y = y, width = width, height = height, font_size = size, weight = weight, color = color or "Foreground", align = align or "left" })
	end

	local function window(id, width, height, x, y, title, icon, head)
		local top = MARGIN + (head or 0)
		local root = skin:window({ id = id, width = width + MARGIN * 2, height = height + top + MARGIN, x = x, y = y, mask = "masks/" .. id .. ".png", visible = id == "main" or skin:pref(id, false) })
		local frame = skin:add(root, { x = MARGIN, y = top + 10, width = width, height = height, pivot = "center", alpha = 0, scale = 0.96 })
		local backdrop = {
			type = "rect", width = width, height = height, shader = "shaders/backdrop.gdshader",
			uniforms = { size = { width, height }, radius = RADIUS, background = "Background", tint = "BackgroundTint", color_1 = "AnimBgColor1", color_2 = "AnimBgColor2", color_3 = "AnimBgColor3", dots = dots, seed = x * 0.01 + y * 0.02 },
		}
		fits[id] = { width = width, height = height, nodes = {} }
		for _, spec in ipairs({
			{ type = "panel", width = width, height = height, radius = RADIUS, shadow = 10, color = "Background" }, backdrop,
			{ type = "panel", width = width, height = height, radius = RADIUS, color = "#00000000", border_width = 1, border_color = "Foreground@0.08" },
		}) do
			fits[id].nodes[#fits[id].nodes + 1] = { node = skin:add(frame, spec), grow = { 0, 0 } }
		end
		fits[id].backdrop = fits[id].nodes[2].node
		fits[id].nodes[#fits[id].nodes + 1] = { node = frame, grow = { 0, 0 } }
		tops[id] = top
		if title then
			skin:add(frame, { type = "image", image = "icons/" .. icon .. ".svg", x = 18, y = 17, width = 22, height = 22, modulate = "Foreground" })
			text(frame, 48, 13, width - 170, 30, 17, 700).text = title
			fits[id].nodes[#fits[id].nodes + 1] = { node = button(frame, "close", width - 42, 12, 30, function() reveal(id, false) end, "Close").holder, right = 42 }
		end
		frames[id] = frame
		return frame
	end

	local function stage(parent, kind, width, height)
		local holder = skin:add(parent, { type = "panel", x = 12, y = 54, width = width - 24, height = height - 74, radius = 10, color = "PanelBg", clip_children = 1 })
		return holder, skin:add(holder, { type = "view", kind = kind, width = width - 24, height = height - 74 })
	end

	local function fit(id, width, height)
		local fitting = fits[id]
		for _, entry in ipairs(fitting.nodes) do
			if entry.grow then
				entry.node.size = Vector2(width + entry.grow[1], height + entry.grow[2])
			else
				entry.node.position = Vector2(entry.right and width - entry.right or entry.node.position.x, entry.bottom and height - entry.bottom or entry.node.position.y)
			end
		end
		frames[id].pivot_offset = Vector2(width / 2, height / 2)
		skin:uniform(fitting.backdrop, "size", { width, height })
	end

	local function resizable(id, min_width, min_height)
		local fitting = fits[id]
		local grip = skin:add(frames[id], { type = "button", x = fitting.width - 20, y = fitting.height - 19, width = 16, height = 16, mouse_default_cursor_shape = 12, tooltip = "Resize" })
		skin:add(grip, { type = "image", image = "images/grip.svg", x = 2, y = 2, width = 12, height = 12, modulate = "Foreground@0.45" })
		grip.button_down:connect(function() skin:resize(id, min_width + MARGIN * 2, min_height + tops[id] + MARGIN) end)
		fitting.nodes[#fitting.nodes + 1] = { node = grip, right = 20, bottom = 19 }
		local width, height = skin:pref(id .. "_width", fitting.width), skin:pref(id .. "_height", fitting.height)
		if width ~= fitting.width or height ~= fitting.height then
			skin:set_window_size(id, width + MARGIN * 2, height + tops[id] + MARGIN)
		end
	end

	nari.on("resized", function(id, width, height)
		width, height = width - MARGIN * 2, height - tops[id] - MARGIN
		fit(id, width, height)
		skin:set_pref(id .. "_width", width)
		skin:set_pref(id .. "_height", height)
	end)

	function reveal(id, open, quiet)
		shown[id] = open
		if toggles[id] then
			light(toggles[id], open)
		end
		if not quiet then
			skin:sound(open and "ui:window_open" or "ui:window_close")
			skin:set_pref(id, open)
		end
		if open then
			idle = 0
			skin:show_window(id, true)
			skin:animate(frames[id], { modulate = SOLID, scale = 1, position = { MARGIN, tops[id] } }, 0.35, { trans = "cubic", ease = "out" })
		else
			skin:animate(frames[id], { modulate = CLEAR, scale = 0.96, position = { MARGIN, tops[id] + 10 } }, 0.2, { trans = "cubic", ease = "in" }).finished:connect(function()
				if not shown[id] then skin:show_window(id, false) end
			end)
		end
	end

	local function toggle(id)
		return function() reveal(id, not shown[id]) end
	end

	local main = window("main", 420, 150, 0, 0, nil, nil, HEAD)
	local cover = skin:add(main, { type = "panel", x = 12, y = 12, width = 126, height = 126, radius = 10, color = "PanelBg", clip_children = 1 })
	skin:add(cover, { type = "view", kind = "cover", x = -12, y = -12, width = 150, height = 150 })
	local title = skin:add(main, { type = "text", x = 150, y = 10, width = 184, height = 28, font_size = 19, weight = 700, color = "Foreground", marquee = true })
	local artist = text(main, 150, 36, 184, 22, 14, 500, "Foreground@0.65")
	button(main, "fullscreen", 342, 12, 28, "back", "Back to Nari")
	button(main, "close", 380, 12, 28, function()
		for id in pairs(shown) do
			if shown[id] then skin:animate(frames[id], { modulate = CLEAR, scale = 0.94 }, 0.22, { trans = "cubic", ease = "in" }) end
		end
		skin:sound("ui:window_close")
		nari.after(0.24, function() skin:close() end)
	end, "Close")
	local pill = skin:add(main, { type = "panel", x = 150, y = 64, width = 258, height = 32, radius = 10, color = "PanelBg" })
	local elapsed = text(pill, 6, 0, 44, 32, 12, 700, "PanelFg", "center")
	local total = text(pill, 208, 0, 44, 32, 12, 700, "PanelFg", "center")
	local seek = skin:add(pill, {
		type = "progress", x = 52, width = 154, height = 18, scale_height = 0.42,
		on_release = function(value) skin:command("seek", value / 1000) end,
	})
	seek.position = Vector2(52, (32 - seek.size.y) / 2)
	button(main, "skip_previous", 150, 104, 34, "previous", "Previous")
	local play = button(main, "play", 188, 104, 34, function() skin:command(skin:deck().state == 3 and "pause" or "play") end, "Play / Pause", true)
	button(main, "skip_next", 226, 104, 34, "next", "Next")
	local show_volume
	local speaker = button(main, "sound", 265, 105, 32, function() show_volume(not popup_open) end, "Volume")
	toggles.effects = button(main, "visualizer", 302, 105, 32, toggle("effects"), "Effects")
	toggles.queue = button(main, "queue_music", 339, 105, 32, toggle("queue"), "Up next")
	button(main, "more", 376, 105, 32, function() skin:menu() end, "More")

	local popup = skin:add(main, { x = 257, y = -65, width = 48, height = 164, pivot = { 24, 164 }, alpha = 0, scale = 0.9, visible = false })
	skin:add(popup, { type = "panel", width = 48, height = 164, radius = 14, shadow = 8, color = "PanelBg", border_width = 1, border_color = "PanelFg@0.08" })
	local volume = skin:add(popup, {
		type = "thin", x = 12, y = 12, width = 24, height = 140, vertical = true, thickness = 6, color = "PanelFg", max_value = 1, step = 0.01,
		grabber = "images/grabber.svg", on_change = function(value) skin:command("volume", value * 100) end,
	})

	function show_volume(open)
		idle = 0
		if open == popup_open then
			return
		end
		popup_open = open
		light(speaker, open)
		skin:set_solid("main", open and { { MARGIN + 249, MARGIN + HEAD - 73, 64, 180 } } or {})
		if open then
			popup.visible = true
			skin:animate(popup, { modulate = SOLID, scale = 1 }, 0.22, { trans = "back", ease = "out" })
		else
			skin:animate(popup, { modulate = CLEAR, scale = 0.9 }, 0.15, { trans = "cubic", ease = "in" }).finished:connect(function()
				if not popup_open then popup.visible = false end
			end)
		end
	end

	speaker.press.mouse_entered:connect(function() show_volume(true) end)

	local effects = window("effects", 420, 240, 0, 218, "Effects", "visualizer")
	local previous_effect = button(effects, "chevron_left", 302, 12, 30, function() skin:command("effect", -1) end, "Previous effect")
	local next_effect = button(effects, "chevron_right", 340, 12, 30, function() skin:command("effect", 1) end, "Next effect")
	local holder, view = stage(effects, "effects", 420, 240)
	for _, entry in ipairs({ { node = previous_effect.holder, right = 118 }, { node = next_effect.holder, right = 80 }, { node = holder, grow = { -24, -74 } }, { node = view, grow = { -24, -74 } } }) do
		fits.effects.nodes[#fits.effects.nodes + 1] = entry
	end
	resizable("effects", 300, 180)

	local queue = window("queue", 300, 380, 428, HEAD, "Up next", "queue_music")
	local list = skin:add(queue, { x = 12, y = 54, width = 276, height = 314, clip_contents = true })
	local empty = text(queue, 12, 54, 276, 60, 15, 500, "Foreground@0.5", "center")
	empty.text = "Nothing queued"
	for index = 1, ROWS do
		local row = skin:add(list, { y = (index - 1) * 62, width = 276, height = 56 })
		local item = { row = row }
		skin:add(row, { type = "panel", width = 276, height = 56, radius = 10, color = "PanelBg" })
		item.shine = skin:add(row, { type = "panel", width = 276, height = 56, radius = 10, color = "PanelFg@0.1", alpha = 0 })
		item.title = text(row, 14, 7, 248, 22, 15, 600, "PanelFg")
		item.artist = text(row, 14, 29, 248, 20, 12, 500, "PanelFg@0.6")
		local press = skin:add(row, { type = "button", width = 276, height = 56, sound = "ui:sub_select", on_click = function() if item.index then skin:command("play_queued", item.index) end end })
		press.mouse_entered:connect(function() skin:animate(item.shine, { modulate = SOLID }, 0.15) end)
		press.mouse_exited:connect(function() skin:animate(item.shine, { modulate = CLEAR }, 0.2) end)
		rows[index] = item
	end

	local function fill_queue(state, animated)
		local first = (state.playing or -1) + 1 + scroll
		for index, item in ipairs(rows) do
			local song = state.queue[first + index]
			item.index = song and first + index - 1 or nil
			item.row.visible = song ~= nil
			if song then
				item.title.text, item.artist.text = song.title, song.artist
				if animated then
					item.row.modulate, item.row.position = CLEAR, Vector2(16, (index - 1) * 62)
					skin:animate(item.row, { modulate = SOLID, position = { 0, (index - 1) * 62 } }, 0.3, { trans = "cubic", ease = "out", delay = index * 0.04 })
				end
			end
		end
		empty.visible = state.queue[first + 1] == nil and scroll == 0
	end

	for id in pairs(frames) do
		if skin:is_shown(id) then
			reveal(id, true, true)
		elseif toggles[id] then
			light(toggles[id], false)
		end
	end

	nari.on("deck", function(state)
		local song = state.song or {}
		if title.text ~= (song.title or "Nothing playing") then
			title.text = song.title or "Nothing playing"
		end
		artist.text = song.artist or "Nari"
		play.icon.texture = skin:texture(state.state == 3 and "icons/pause.svg" or "icons/play.svg")
		seek.playing = state.state == 3
		if not volume:is_dragging() then
			volume.value = state.volume / 100
		end
		local mark = tostring(state.playing) .. ":" .. #state.queue
		local moved = mark ~= queue_mark
		if moved then
			queue_mark, scroll = mark, 0
		end
		fill_queue(state, moved)
	end)

	nari.on("frame", function(delta)
		local length, position = MediaPlayer:get_duration(), MediaPlayer:get_position()
		seek.max_value = math.max(length, 1)
		if not seek:is_held() then
			seek.value = position
			elapsed.text = clock(position)
		end
		total.text = clock(length)
		local mouse = popup:get_local_mouse_position()
		local near = mouse.x > -10 and mouse.x < 58 and mouse.y > -10 and mouse.y < 210
		idle = (volume:is_dragging() or near) and 0 or idle + delta
		if popup_open and idle > 0.6 then
			show_volume(false)
		end
	end)

	nari.on("wheel", function(amount, id)
		local state = skin:deck()
		if id == "queue" then
			scroll = math.max(0, math.min(scroll - amount, #state.queue - (state.playing or -1) - ROWS - 1))
			fill_queue(state)
		elseif id == "main" then
			skin:command("volume", math.max(0, math.min(100, state.volume + amount * 5)))
			show_volume(true)
		end
	end)

	nari.on("key", function(code, pressed)
		if pressed and code == 32 then
			skin:command(skin:deck().state == 3 and "pause" or "play")
		elseif pressed and (code == 37 or code == 39) then
			skin:command("seek_by", code == 37 and -5000 or 5000)
		end
	end)
end)
