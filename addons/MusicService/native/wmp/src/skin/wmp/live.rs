use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::time::Instant;

use super::super::script::{Code, Value};
use super::picture::ImageKey;
use super::predefined::{self, color};
use super::xml::Node;
use super::{Box2, Wmp};
use crate::skin::Rgb;

pub type ElementId = usize;

pub const ELEMENT_BASE: u64 = 1 << 40;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    View,
    SubView,
    Button,
    ButtonGroup,
    ButtonElement,
    Slider,
    CustomSlider,
    Text,
    Video,
    Effects,
    Playlist,
    ListBox,
    EditBox,
    Player,
    Equalizer,
    VideoSettings,
    Other,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Anchor {
    #[default]
    Start,
    End,
    Center,
    Stretch,
}

impl Anchor {
    fn of(value: &str) -> Anchor {
        match value.trim().to_ascii_lowercase().as_str() {
            "right" | "bottom" => Anchor::End,
            "center" => Anchor::Center,
            "stretch" => Anchor::Stretch,
            _ => Anchor::Start,
        }
    }
}

#[derive(Clone, Debug)]
pub enum Handler {
    Source(Arc<str>),
    Function(Value),
}

pub struct Element {
    pub kind: Kind,
    pub tag: &'static str,
    pub id: Option<String>,
    pub parent: Option<ElementId>,
    pub children: Vec<ElementId>,
    pub props: HashMap<String, Value>,
    pub handlers: HashMap<String, Handler>,
    pub left: f64,
    pub top: f64,
    pub width: f64,
    pub height: f64,
    pub auto_width: bool,
    pub auto_height: bool,
    pub visible: bool,
    pub enabled: bool,
    pub z: i32,
    pub alpha: f64,
    pub across: Anchor,
    pub down: Anchor,
    pub items: Vec<String>,
    pub selected: Option<usize>,
    pub scroll: f64,
    pub scrolling_since: Option<Instant>,
    pub shown: HashMap<&'static str, (ImageKey, Instant)>,
    pub popped: bool,
}

pub fn literal(key: &str, value: &str) -> Value {
    let text_like = matches!(
        key,
        "id" | "title"
            | "uptooltip"
            | "downtooltip"
            | "tooltip"
            | "columns"
            | "image"
            | "hoverimage"
            | "downimage"
            | "backgroundimage"
    );
    if !text_like {
        if value.eq_ignore_ascii_case("true") {
            return Value::Bool(true);
        }
        if value.eq_ignore_ascii_case("false") {
            return Value::Bool(false);
        }
        if key != "value"
            && !value.is_empty()
            && let Ok(number) = value.trim().parse::<f64>()
        {
            return Value::Number(number);
        }
    }
    Value::Str(value.into())
}

pub fn text_of(value: &Value) -> String {
    match value {
        Value::Str(text) => text.to_string(),
        Value::Number(number) if number.fract() == 0.0 && number.abs() < 1e15 => {
            format!("{}", *number as i64)
        }
        Value::Number(number) => number.to_string(),
        Value::Bool(true) => "true".into(),
        Value::Bool(false) => "false".into(),
        _ => String::new(),
    }
}

pub fn number_of(value: &Value) -> f64 {
    match value {
        Value::Number(number) => *number,
        Value::Str(text) => text.trim().parse().unwrap_or(0.0),
        Value::Bool(true) => 1.0,
        _ => 0.0,
    }
}

pub fn truthy(value: &Value) -> bool {
    match value {
        Value::Str(text) => {
            !text.is_empty() && !text.eq_ignore_ascii_case("false") && &**text != "0"
        }
        other => crate::skin::script::to_bool(other),
    }
}

impl Element {
    pub fn str(&self, name: &str) -> Option<String> {
        self.props.get(name).map(text_of)
    }

    pub fn image_name(&self, name: &str) -> Option<String> {
        self.str(name).filter(|text| !text.is_empty())
    }

    pub fn num(&self, name: &str, default: f64) -> f64 {
        self.props.get(name).map_or(default, number_of)
    }

    pub fn flag(&self, name: &str, default: bool) -> bool {
        self.props.get(name).map_or(default, truthy)
    }

    pub fn color(&self, name: &str) -> Option<Rgb> {
        self.str(name).and_then(|text| color(&text))
    }

    pub fn behaves(&self) -> bool {
        match self.kind {
            Kind::Slider | Kind::CustomSlider => true,
            Kind::Playlist | Kind::ListBox | Kind::EditBox => true,
            Kind::Button | Kind::ButtonElement | Kind::Text | Kind::Video | Kind::Effects => {
                self.handlers.keys().any(|key| {
                    matches!(
                        key.as_str(),
                        "onclick" | "ondblclick" | "onmousedown" | "onmouseup"
                    )
                }) || self.flag("sticky", false)
            }
            Kind::View => false,
            _ => self
                .handlers
                .keys()
                .any(|key| matches!(key.as_str(), "onclick" | "ondblclick" | "onmousedown")),
        }
    }

    pub fn host(id: ElementId) -> u64 {
        ELEMENT_BASE + id as u64
    }
}

pub struct Motion {
    pub element: ElementId,
    pub start: Instant,
    pub ms: f64,
    pub from: [f64; 5],
    pub to: [f64; 5],
    pub eased: bool,
    pub fade: bool,
}

pub struct Queued {
    pub scope: u64,
    pub handler: Handler,
    pub args: Vec<(String, Value)>,
}

pub struct Binding {
    pub element: ElementId,
    pub attr: String,
    pub code: Arc<str>,
    pub negate: bool,
    pub compiled: Option<Code>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WindowCommand {
    Drag,
    Minimize,
    Maximize,
    Restore,
    Resize(Edge),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Edge {
    North,
    South,
    East,
    West,
    NorthEast,
    NorthWest,
    SouthEast,
    SouthWest,
}

pub struct ViewState {
    pub key: u32,
    pub definition: usize,
    pub id: String,
    pub wmp: Arc<Wmp>,
    pub elements: Vec<Element>,
    pub root: ElementId,
    pub ids: HashMap<String, ElementId>,
    pub players: Vec<ElementId>,
    pub queue: VecDeque<Queued>,
    pub bindings: Vec<Binding>,
    pub motions: Vec<Motion>,
    pub timer_due: Option<Instant>,
    pub hover: Option<ElementId>,
    pub pressed: Option<ElementId>,
    pub dragging: Option<ElementId>,
    pub focus: Option<ElementId>,
    pub pointer: (f32, f32),
    pub window: Vec<WindowCommand>,
    pub last_click: Option<(ElementId, Instant)>,
    pub resizing: bool,
    pub closing: bool,
    pub changed: bool,
    pub bindings_stale: bool,
    pub now: Instant,
    pub deferred: Vec<(ElementId, String, Arc<str>)>,
    pub dropped_events: u32,
}

impl ViewState {
    pub fn new(wmp: Arc<Wmp>, key: u32, definition: usize, now: Instant) -> Self {
        let node = wmp.views.get(definition).cloned().unwrap_or_default();
        let mut view = Self {
            key,
            definition,
            id: node.attr("id").unwrap_or_default().to_owned(),
            wmp,
            elements: Vec::new(),
            root: 0,
            ids: HashMap::new(),
            players: Vec::new(),
            queue: VecDeque::new(),
            bindings: Vec::new(),
            motions: Vec::new(),
            timer_due: None,
            hover: None,
            pressed: None,
            dragging: None,
            focus: None,
            pointer: (-1.0, -1.0),
            window: Vec::new(),
            last_click: None,
            resizing: false,
            closing: false,
            changed: true,
            bindings_stale: false,
            now,
            deferred: Vec::new(),
            dropped_events: 0,
        };
        view.build(&node, None);
        view.elements[view.root].visible = true;
        view
    }

    fn build(&mut self, node: &Node, parent: Option<ElementId>) -> Option<ElementId> {
        if matches!(node.name.as_str(), "item" | "column") {
            if node.name == "item"
                && let Some(parent) = parent
                && let Some(value) = node.attr("value")
            {
                self.elements[parent].items.push(value.to_owned());
            }
            return None;
        }
        let (tag, defaults) = predefined::expand(&node.name);
        let kind = match tag {
            "view" => Kind::View,
            "subview" => Kind::SubView,
            "button" => Kind::Button,
            "buttongroup" => Kind::ButtonGroup,
            "buttonelement" => Kind::ButtonElement,
            "slider" => Kind::Slider,
            "customslider" => Kind::CustomSlider,
            "text" => Kind::Text,
            "video" => Kind::Video,
            "effects" => Kind::Effects,
            "playlist" => Kind::Playlist,
            "listbox" => Kind::ListBox,
            "editbox" => Kind::EditBox,
            "player" => Kind::Player,
            "equalizersettings" => Kind::Equalizer,
            "videosettings" => Kind::VideoSettings,
            _ => Kind::Other,
        };
        let id = self.elements.len();
        self.elements.push(Element {
            kind,
            tag,
            id: None,
            parent,
            children: Vec::new(),
            props: HashMap::new(),
            handlers: HashMap::new(),
            left: 0.0,
            top: 0.0,
            width: 0.0,
            height: 0.0,
            auto_width: true,
            auto_height: true,
            visible: !matches!(tag, "listbox") || node.attr("popup").is_none(),
            enabled: true,
            z: 0,
            alpha: 255.0,
            across: Anchor::Start,
            down: Anchor::Start,
            items: Vec::new(),
            selected: None,
            scroll: 0.0,
            scrolling_since: None,
            shown: HashMap::new(),
            popped: false,
        });
        if defaults.contains(&("popup", "true")) {
            self.elements[id].visible = false;
        }
        if let Some(parent) = parent {
            self.elements[parent].children.push(id);
        }
        if kind == Kind::Player {
            self.players.push(id);
        }
        for (key, value) in defaults {
            self.attribute(id, key, value);
        }
        for (key, value) in &node.attrs {
            self.attribute(id, key, value);
        }
        if let Some(name) = node.first_attr("id") {
            let name = name.to_owned();
            self.ids.entry(name.to_ascii_lowercase()).or_insert(id);
            self.elements[id].id = Some(name);
        }
        for child in &node.children {
            self.build(child, Some(id));
        }
        Some(id)
    }

    fn attribute(&mut self, id: ElementId, key: &str, value: &str) {
        let trimmed = value.trim();
        let lower_head = trimmed.get(..12).unwrap_or(trimmed).to_ascii_lowercase();
        let kind = self.elements[id].kind;
        let handler_like = key.ends_with("_onchange")
            || key.starts_with("on")
            || (kind == Kind::Player && key != "url");
        if handler_like {
            let key = if kind == Kind::Player {
                key.strip_prefix("on").unwrap_or(key)
            } else {
                key
            };
            self.elements[id]
                .handlers
                .insert(key.to_owned(), Handler::Source(value.into()));
            return;
        }
        let strip = |prefix: &str| trimmed.get(prefix.len()..).unwrap_or("").to_owned();
        if lower_head.starts_with("wmpprop:") {
            self.bind(id, key, strip("wmpprop:"), false);
        } else if lower_head.starts_with("wmpenabled:") {
            self.bind(id, key, availability(&strip("wmpenabled:")), false);
        } else if lower_head.starts_with("wmpdisabled:") {
            self.bind(id, key, availability(&strip("wmpdisabled:")), true);
        } else if lower_head.starts_with("jscript:") {
            self.bindings.retain(|b| b.element != id || b.attr != key);
            self.deferred.retain(|d| d.0 != id || d.1 != key);
            self.deferred
                .push((id, key.to_owned(), strip("jscript:").into()));
        } else {
            self.bindings.retain(|b| b.element != id || b.attr != key);
            self.deferred.retain(|d| d.0 != id || d.1 != key);
            self.store(id, key, literal(key, value));
        }
    }

    fn bind(&mut self, id: ElementId, key: &str, code: String, negate: bool) {
        self.bindings.retain(|b| b.element != id || b.attr != key);
        self.deferred.retain(|d| d.0 != id || d.1 != key);
        self.bindings.push(Binding {
            element: id,
            attr: key.to_owned(),
            code: code.as_str().into(),
            negate,
            compiled: None,
        });
    }

    pub fn store(&mut self, id: ElementId, key: &str, value: Value) {
        let element = &mut self.elements[id];
        match key {
            "left" => element.left = number_of(&value),
            "top" => element.top = number_of(&value),
            "width" => {
                element.width = number_of(&value).max(0.0);
                element.auto_width = false;
            }
            "height" => {
                element.height = number_of(&value).max(0.0);
                element.auto_height = false;
            }
            "visible" => element.visible = truthy(&value),
            "enabled" => element.enabled = truthy(&value),
            "zindex" => element.z = number_of(&value) as i32,
            "alphablend" => element.alpha = number_of(&value).clamp(0.0, 255.0),
            "horizontalalignment" => element.across = Anchor::of(&text_of(&value)),
            "verticalalignment" => element.down = Anchor::of(&text_of(&value)),
            _ => {}
        }
        element.props.insert(key.to_owned(), value);
    }

    pub fn set(&mut self, id: ElementId, key: &str, value: Value) {
        if id >= self.elements.len() {
            return;
        }
        if key.starts_with("on") {
            let handler = match &value {
                Value::Object(_) => Handler::Function(value.clone()),
                other => Handler::Source(text_of(other).as_str().into()),
            };
            self.elements[id].handlers.insert(key.to_owned(), handler);
            return;
        }
        let (old_width, old_height) = (self.elements[id].width, self.elements[id].height);
        let same = match key {
            "left" => self.elements[id].left == number_of(&value),
            "top" => self.elements[id].top == number_of(&value),
            "width" => old_width == number_of(&value).max(0.0),
            "height" => old_height == number_of(&value).max(0.0),
            "visible" => self.elements[id].visible == truthy(&value),
            "enabled" => self.elements[id].enabled == truthy(&value),
            _ => self.elements[id].props.get(key) == Some(&value),
        };
        if same {
            if matches!(key, "width") {
                self.elements[id].auto_width = false;
            } else if matches!(key, "height") {
                self.elements[id].auto_height = false;
            }
            return;
        }
        self.store(id, key, value);
        self.changed = true;
        self.bindings_stale = true;
        if matches!(
            key,
            "image" | "backgroundimage" | "positionimage" | "mappingimage"
        ) {
            self.size_from_picture(id);
        }
        let (width, height) = (self.elements[id].width, self.elements[id].height);
        if width != old_width || height != old_height {
            self.resized(id, width - old_width, height - old_height);
        }
        self.notify(id, key);
    }

    pub fn notify(&mut self, id: ElementId, key: &str) {
        let name = format!("{key}_onchange");
        if let Some(handler) = self.elements[id].handlers.get(&name).cloned() {
            self.queue_handler(Element::host(id), handler, Vec::new());
        }
    }

    pub fn queue_handler(&mut self, scope: u64, handler: Handler, args: Vec<(String, Value)>) {
        if self.queue.len() >= 2048 {
            self.dropped_events = self.dropped_events.saturating_add(1);
            return;
        }
        self.queue.push_back(Queued {
            scope,
            handler,
            args,
        });
    }

    pub fn fire(&mut self, id: ElementId, name: &str, args: Vec<(String, Value)>) {
        if let Some(handler) = self
            .elements
            .get(id)
            .and_then(|e| e.handlers.get(name))
            .cloned()
        {
            self.queue_handler(Element::host(id), handler, args);
        }
    }

    pub fn resized(&mut self, id: ElementId, grew_x: f64, grew_y: f64) {
        for child in self.elements[id].children.clone() {
            let element = &mut self.elements[child];
            let (mut wider, mut taller) = (0.0, 0.0);
            match element.across {
                Anchor::Start => {}
                Anchor::End => element.left += grew_x,
                Anchor::Center => element.left += grew_x / 2.0,
                Anchor::Stretch => {
                    element.width = (element.width + grew_x).max(0.0);
                    wider = grew_x;
                }
            }
            match element.down {
                Anchor::Start => {}
                Anchor::End => element.top += grew_y,
                Anchor::Center => element.top += grew_y / 2.0,
                Anchor::Stretch => {
                    element.height = (element.height + grew_y).max(0.0);
                    taller = grew_y;
                }
            }
            if wider != 0.0 || taller != 0.0 {
                self.resized(child, wider, taller);
            }
        }
        self.fire(id, "onresize", Vec::new());
        self.changed = true;
        self.bindings_stale = true;
    }

    fn picture_size(&self, id: ElementId) -> Option<(u32, u32)> {
        let element = &self.elements[id];
        let names: &[&str] = match element.kind {
            Kind::Button => &["image"],
            Kind::ButtonGroup => &["mappingimage", "image"],
            Kind::SubView | Kind::View => &["backgroundimage"],
            Kind::Slider => &["backgroundimage", "foregroundimage", "image"],
            Kind::CustomSlider => &["positionimage"],
            _ => &[],
        };
        names
            .iter()
            .filter_map(|name| element.image_name(name))
            .find_map(|name| self.wmp.size_of(&name))
    }

    pub fn size_from_picture(&mut self, id: ElementId) {
        if let Some((width, height)) = self.picture_size(id) {
            let element = &mut self.elements[id];
            if element.auto_width {
                element.width = f64::from(width);
            }
            if element.auto_height {
                element.height = f64::from(height);
            }
        }
    }

    pub fn settle_sizes(&mut self) {
        for id in 0..self.elements.len() {
            self.size_from_picture(id);
            let kind = self.elements[id].kind;
            if kind == Kind::Slider && self.elements[id].height == 0.0 {
                let thumb = self.elements[id]
                    .image_name("thumbimage")
                    .and_then(|name| self.wmp.size_of(&name));
                if let Some((width, height)) = thumb {
                    let element = &mut self.elements[id];
                    if element.auto_height {
                        element.height = f64::from(height);
                    }
                    if element.auto_width && element.width == 0.0 {
                        element.width = f64::from(width);
                    }
                }
            }
            let Some(parent) = self.elements[id].parent else {
                continue;
            };
            if matches!(kind, Kind::SubView | Kind::Effects | Kind::Video)
                && self.picture_size(id).is_none()
            {
                let (parent_width, parent_height) =
                    (self.elements[parent].width, self.elements[parent].height);
                let element = &mut self.elements[id];
                if element.auto_width {
                    element.width = (parent_width - element.left).max(0.0);
                }
                if element.auto_height {
                    element.height = (parent_height - element.top).max(0.0);
                }
            }
        }
    }

    pub fn settle_view_size(&mut self) {
        let root = self.root;
        if self.elements[root].width > 0.0 && self.elements[root].height > 0.0 {
            return;
        }
        let (mut right, mut bottom) = (0.0f64, 0.0f64);
        for child in self.elements[root].children.clone() {
            let element = &self.elements[child];
            if matches!(
                element.kind,
                Kind::Player | Kind::Equalizer | Kind::VideoSettings | Kind::Other
            ) || !element.visible
            {
                continue;
            }
            right = right.max(element.left + element.width);
            bottom = bottom.max(element.top + element.height);
        }
        let element = &mut self.elements[root];
        if element.width <= 0.0 {
            element.width = right;
        }
        if element.height <= 0.0 {
            element.height = bottom;
        }
    }

    pub fn settle_centres(&mut self) {
        for id in 0..self.elements.len() {
            let Some(parent) = self.elements[id].parent else {
                continue;
            };
            let (parent_width, parent_height) =
                (self.elements[parent].width, self.elements[parent].height);
            let element = &mut self.elements[id];
            if element.across == Anchor::Center && !element.props.contains_key("left") {
                element.left = ((parent_width - element.width) / 2.0).floor();
            }
            if element.down == Anchor::Center && !element.props.contains_key("top") {
                element.top = ((parent_height - element.height) / 2.0).floor();
            }
        }
    }

    pub fn in_order(&self, id: ElementId) -> Vec<ElementId> {
        let mut children = self.elements[id].children.clone();
        children.sort_by_key(|child| self.elements[*child].z);
        children
    }

    pub fn world_box(&self, id: ElementId) -> Box2 {
        let (mut x, mut y) = (0.0, 0.0);
        let mut at = Some(id);
        while let Some(current) = at {
            if current != self.root {
                x += self.elements[current].left;
                y += self.elements[current].top;
            }
            at = self.elements[current].parent;
        }
        let element = &self.elements[id];
        Box2 {
            x: x.round() as i32,
            y: y.round() as i32,
            width: element.width.round() as i32,
            height: element.height.round() as i32,
        }
    }

    pub fn size(&self) -> (f64, f64) {
        let root = &self.elements[self.root];
        (root.width, root.height)
    }

    pub fn windowed(&self) -> bool {
        let (width, height) = self.size();
        width >= 1.0 && height >= 1.0
    }
}

fn availability(path: &str) -> String {
    let name = path
        .trim()
        .trim_end_matches(';')
        .trim_end_matches("()")
        .rsplit('.')
        .next()
        .unwrap_or("")
        .replace(['\'', '"'], "");
    format!("player.controls.isAvailable('{name}')")
}
