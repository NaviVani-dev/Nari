class_name PlexLogin extends VBoxContainer

signal connected

const SCENE := "res://ui/shared/PlexLogin.tscn"
const POLL_TIME := 2.0

@onready var _code: NariLabel = %Code
@onready var _status: NariLabel = %Status
@onready var _accept: NariButton = %AcceptButton

var provider: PlexMusicProvider
var _auth_url := ""
var _session := 0
var _failed := false

static func open(plex: PlexMusicProvider) -> void:
	var dialog := Dialog.new()
	dialog.dismissable = true
	var login: PlexLogin = load(SCENE).instantiate()
	login.provider = plex
	login.connected.connect(dialog.close)
	dialog.closed.connect(login.cancel)
	dialog.content.add_child(login)
	dialog.add_button("Cancel")
	dialog.popup()

func _ready() -> void:
	UI.paint_button(_accept, true)
	_accept.pressed.connect(func():
		if _failed:
			_start()
		elif not _auth_url.is_empty():
			OS.shell_open(_auth_url))
	_start()

func cancel() -> void:
	_session += 1

func _start() -> void:
	_session += 1
	var session := _session
	_failed = false
	_auth_url = ""
	_accept.disabled = true
	_accept.text = "Open browser"
	_code.text = "····"
	var pin: Dictionary = await provider.request_pin()
	if session != _session:
		return
	if not pin.has("code"):
		_show_error("Could not reach plex.tv")
		return
	_status.hide()
	_code.text = str(pin["code"])
	_auth_url = str(pin["auth_url"])
	_accept.disabled = false
	var deadline := Time.get_ticks_msec() + int(pin.get("expiresIn", 900)) * 1000
	while session == _session:
		await get_tree().create_timer(POLL_TIME).timeout
		if session != _session:
			return
		if Time.get_ticks_msec() > deadline:
			_start()
			return
		var token: String = await provider.check_pin(str(pin.get("id", "")))
		if session == _session and not token.is_empty():
			_session += 1
			_pick_server(token)
			return

func _pick_server(token: String) -> void:
	_code.text = "····"
	_accept.disabled = true
	var servers: Array = await provider.find_servers(token)
	if servers.is_empty():
		_show_error("No Plex Media Server was found on this account")
		return
	if servers.size() == 1:
		_connect(servers[0])
		return
	var menu := Dialog.menu("Choose a server")
	for server: Dictionary in servers:
		menu.add_option(str(server.get("name", "Plex")), _connect.bind(server), preload("res://assets/icons/plex.svg"))
	menu.popup()

func _connect(server: Dictionary) -> void:
	var error: String = await provider.use_server(server)
	if error.is_empty():
		connected.emit()
	else:
		_show_error(error)

func _show_error(message: String) -> void:
	_status.text = message
	_status.show()
	_accept.disabled = false
	_accept.text = "Try again"
	_failed = true
