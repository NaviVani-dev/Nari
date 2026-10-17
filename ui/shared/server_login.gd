class_name ServerLogin extends VBoxContainer

signal submitted(url: String, user: String, password: String)

@onready var _url_edit: NariLineEdit = %UrlEdit
@onready var _user_edit: NariLineEdit = %UserEdit
@onready var _password_edit: NariLineEdit = %PasswordEdit
@onready var _status: NariLabel = %Status
@onready var _accept: NariButton = %AcceptButton

var url: = ""
var user: = ""

func _ready() -> void:
	_url_edit.text = url
	_user_edit.text = user
	for edit in [_url_edit, _user_edit, _password_edit]:
		edit.text_changed.connect(func(_text: String): _validate())
		edit.text_submitted.connect(func(_text: String): _submit())
	UI.paint_button(_accept, true)
	_accept.pressed.connect(_submit)
	_validate()

func set_busy(busy: bool) -> void:
	_accept.disabled = busy
	_accept.text = "Signing in..." if busy else "Sign in"
	if busy:
		_status.hide()

func show_error(message: String) -> void:
	set_busy(false)
	_status.text = message
	_status.show()

func _validate() -> void:
	_accept.disabled = _url_edit.text.strip_edges().is_empty() or _user_edit.text.strip_edges().is_empty() or _password_edit.text.is_empty()

func _submit() -> void:
	if _accept.disabled:
		return
	set_busy(true)
	submitted.emit(_url_edit.text.strip_edges(), _user_edit.text.strip_edges(), _password_edit.text)
