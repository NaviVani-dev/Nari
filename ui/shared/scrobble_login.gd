class_name ScrobbleLogin extends VBoxContainer

signal connected

const SCENE := "res://ui/shared/ScrobbleLogin.tscn"
const SERVICES := {"lastfm": "Last.fm", "librefm": "Libre.fm", "listenbrainz": "ListenBrainz"}

@onready var _title: NariLabel = %Title
@onready var _hint: NariLabel = %Hint
@onready var _token_edit: NariLineEdit = %TokenEdit
@onready var _status: NariLabel = %Status
@onready var _accept: NariButton = %AcceptButton

var service := ""
var _native: Object = Engine.get_singleton("MusicService") if Engine.has_singleton("MusicService") else null
var _url := ""

static func open(service_id: String) -> void:
	var dialog := Dialog.new()
	dialog.dismissable = true
	var login: ScrobbleLogin = load(SCENE).instantiate()
	login.service = service_id
	login.connected.connect(dialog.close)
	dialog.closed.connect(login.cancel)
	dialog.content.add_child(login)
	dialog.add_button("Cancel")
	dialog.popup()

static func accounts() -> Dictionary:
	return JsonUtil.parse_dict(Engine.get_singleton("MusicService").getScrobbleAccountsJson()) if Engine.has_singleton("MusicService") else {}

func _ready() -> void:
	_title.text = "Connect %s" % SERVICES[service]
	_token_edit.visible = _uses_token()
	_hint.text = "Paste your user token from listenbrainz.org/settings" if _uses_token() else "Your browser will open so you can let Nari scrobble to your account"
	_token_edit.text_submitted.connect(func(_text: String): _submit())
	UI.paint_button(_accept, true)
	_accept.pressed.connect(_submit)
	if _native:
		_native.connect("scrobble_auth_url", _on_auth_url)
		_native.connect("scrobble_account_changed", _on_account_changed)
	_set_busy(false)

func _uses_token() -> bool:
	return service == "listenbrainz"

func _set_busy(busy: bool) -> void:
	_accept.disabled = busy or not _native
	if busy:
		_accept.text = "Connecting..."
		_status.hide()
	elif not _url.is_empty():
		_accept.text = "Open browser again"
	else:
		_accept.text = "Connect" if _uses_token() else "Open browser"

func _submit() -> void:
	if _accept.disabled or (_uses_token() and _token_edit.text.strip_edges().is_empty()):
		return
	if not _url.is_empty():
		OS.shell_open(_url)
		return
	_set_busy(true)
	if _uses_token():
		_native.scrobbleSetToken(_token_edit.text.strip_edges())
	else:
		_native.scrobbleConnect(service)

func cancel() -> void:
	if _native:
		_native.scrobbleCancel(service)

func _on_auth_url(from: String, url: String) -> void:
	if from != service:
		return
	_url = url
	_hint.text = "Allow Nari in your browser. It connects by itself once you do"
	OS.shell_open(url)
	_set_busy(false)

func _on_account_changed(from: String, error: String) -> void:
	if from != service:
		return
	if error.is_empty():
		connected.emit()
		return
	_url = ""
	_set_busy(false)
	_status.text = error
	_status.show()
