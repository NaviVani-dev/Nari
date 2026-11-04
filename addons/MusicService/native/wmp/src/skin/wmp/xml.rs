const MAX_DEPTH: usize = 32;
const MAX_NODES: usize = 100_000;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Node {
    pub name: String,
    pub attrs: Vec<(String, String)>,
    pub children: Vec<Node>,
}

impl Node {
    pub fn attr(&self, name: &str) -> Option<&str> {
        self.attrs
            .iter()
            .rev()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.as_str())
    }

    pub fn first_attr(&self, name: &str) -> Option<&str> {
        self.attrs
            .iter()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.as_str())
    }

    pub fn find(&self, name: &str) -> Option<&Node> {
        if self.name == name {
            return Some(self);
        }
        self.children.iter().find_map(|child| child.find(name))
    }

    pub fn walk<'a>(&'a self, visit: &mut impl FnMut(&'a Node)) {
        visit(self);
        for child in &self.children {
            child.walk(visit);
        }
    }
}

#[derive(Debug)]
pub struct Tag {
    pub name: String,
    pub closing: bool,
    pub self_closing: bool,
    pub attrs: Vec<(String, String)>,
}

pub fn parse(text: &str) -> Node {
    let mut stack = vec![Node::default()];
    let mut count = 0usize;
    for tag in tags(text) {
        if tag.closing {
            if let Some(at) = stack.iter().rposition(|node| node.name == tag.name)
                && at > 0
            {
                while stack.len() > at {
                    close(&mut stack);
                }
            }
            continue;
        }
        count += 1;
        if count > MAX_NODES {
            break;
        }
        let node = Node {
            name: tag.name,
            attrs: tag.attrs,
            children: Vec::new(),
        };
        if tag.self_closing || stack.len() >= MAX_DEPTH {
            if let Some(parent) = stack.last_mut() {
                parent.children.push(node);
            }
        } else {
            stack.push(node);
        }
    }
    while stack.len() > 1 {
        close(&mut stack);
    }
    stack.pop().unwrap_or_default()
}

fn close(stack: &mut Vec<Node>) {
    if let Some(node) = stack.pop()
        && let Some(parent) = stack.last_mut()
    {
        parent.children.push(node);
    }
}

pub fn tags(text: &str) -> Vec<Tag> {
    let mut found = Vec::new();
    let mut rest = text;
    while let Some(start) = rest.find('<') {
        rest = &rest[start + 1..];
        if let Some(after) = rest.strip_prefix("!--") {
            rest = after.split_once("-->").map_or("", |(_, tail)| tail);
            continue;
        }
        if rest.starts_with('?') || rest.starts_with('!') {
            rest = rest.split_once('>').map_or("", |(_, tail)| tail);
            continue;
        }
        let mut quote = None;
        let mut end = rest.len();
        for (at, character) in rest.char_indices() {
            match (quote, character) {
                (None, '"' | '\'') => quote = Some(character),
                (Some(open), c) if c == open => quote = None,
                (None, '>') => {
                    end = at;
                    break;
                }
                _ => {}
            }
        }
        let body = &rest[..end];
        rest = rest.get(end + 1..).unwrap_or("");
        found.extend(parse_tag(body));
    }
    found
}

fn parse_tag(body: &str) -> Option<Tag> {
    let mut body = body.trim();
    let closing = body.starts_with('/');
    body = body.trim_start_matches('/').trim();
    let self_closing = body.ends_with('/');
    body = body.trim_end_matches('/').trim();
    let name_end = body.find(|c: char| c.is_whitespace()).unwrap_or(body.len());
    let name = body[..name_end].to_ascii_lowercase();
    if name.is_empty() {
        return None;
    }
    let mut attrs = Vec::new();
    let mut rest = &body[name_end..];
    loop {
        rest = rest.trim_start();
        let key_end = rest
            .find(|c: char| c == '=' || c.is_whitespace())
            .unwrap_or(rest.len());
        if key_end == 0 {
            match rest.strip_prefix('=') {
                Some(after) => {
                    rest = after;
                    continue;
                }
                None => break,
            }
        }
        let key = rest[..key_end].to_ascii_lowercase();
        rest = rest[key_end..].trim_start();
        let Some(after) = rest.strip_prefix('=') else {
            attrs.push((key, String::new()));
            continue;
        };
        let after = after.trim_start();
        let (value, tail) = match after.chars().next() {
            Some(open @ ('"' | '\'')) => {
                let inner = &after[1..];
                let close = inner.find(open).unwrap_or(inner.len());
                (&inner[..close], inner.get(close + 1..).unwrap_or(""))
            }
            _ => {
                let end = after.find(char::is_whitespace).unwrap_or(after.len());
                (&after[..end], &after[end..])
            }
        };
        attrs.push((key, unescape(value)));
        rest = tail;
    }
    Some(Tag {
        name,
        closing,
        self_closing,
        attrs,
    })
}

fn unescape(value: &str) -> String {
    if !value.contains('&') {
        return value.to_owned();
    }
    let mut out = String::with_capacity(value.len());
    let mut rest = value;
    while let Some(at) = rest.find('&') {
        out.push_str(&rest[..at]);
        rest = &rest[at..];
        let entity = rest
            .find(';')
            .filter(|end| *end <= 10)
            .map(|end| &rest[1..end]);
        let decoded = entity.and_then(|entity| match entity {
            "quot" => Some('"'),
            "apos" => Some('\''),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "amp" => Some('&'),
            _ => {
                let digits = entity.strip_prefix('#')?;
                let code = match digits.strip_prefix(['x', 'X']) {
                    Some(hex) => u32::from_str_radix(hex, 16).ok()?,
                    None => digits.parse().ok()?,
                };
                char::from_u32(code)
            }
        });
        match (decoded, entity) {
            (Some(character), Some(entity)) => {
                out.push(character);
                rest = &rest[entity.len() + 2..];
            }
            _ => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}
