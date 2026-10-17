use deunicode::deunicode_char;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WritingSystem {
    Japanese,
    Chinese,
    Korean,
    Cyrillic,
    Greek,
    Arabic,
    Other,
}

impl WritingSystem {
    const ALL: [Self; 7] = [
        Self::Japanese,
        Self::Chinese,
        Self::Korean,
        Self::Cyrillic,
        Self::Greek,
        Self::Arabic,
        Self::Other,
    ];

    const fn index(self) -> usize {
        match self {
            Self::Japanese => 0,
            Self::Chinese => 1,
            Self::Korean => 2,
            Self::Cyrillic => 3,
            Self::Greek => 4,
            Self::Arabic => 5,
            Self::Other => 6,
        }
    }
}

pub fn lines(texts: &[String]) -> Vec<String> {
    let Some(system) = detect(texts.iter().map(String::as_str)) else {
        return vec![String::new(); texts.len()];
    };
    texts
        .iter()
        .map(|text| convert(text, system).unwrap_or_default())
        .collect()
}

fn detect<'a>(texts: impl Iterator<Item = &'a str>) -> Option<WritingSystem> {
    let text = texts.collect::<Vec<_>>().join("\n");
    if text.chars().any(super::japanese::kana) {
        return Some(WritingSystem::Japanese);
    }
    dominant_system(&text)
}

fn convert(text: &str, system: WritingSystem) -> Option<String> {
    let romanized = match system {
        WritingSystem::Japanese => super::japanese::romanize(text),
        _ => universal(text),
    };
    let romanized = tidy(&romanized);
    (!romanized.is_empty() && romanized != tidy(text)).then_some(romanized)
}

fn dominant_system(text: &str) -> Option<WritingSystem> {
    let mut counts = [0usize; WritingSystem::ALL.len()];
    for letter in text.chars().filter(|letter| non_latin_letter(*letter)) {
        counts[system_of(letter).index()] += 1;
    }
    counts
        .into_iter()
        .enumerate()
        .filter(|(_, count)| *count > 0)
        .max_by_key(|(_, count)| *count)
        .map(|(index, _)| WritingSystem::ALL[index])
}

fn system_of(letter: char) -> WritingSystem {
    match letter as u32 {
        0x3400..=0x4dbf | 0x4e00..=0x9fff | 0xf900..=0xfaff | 0x20000..=0x323af => {
            WritingSystem::Chinese
        }
        0x1100..=0x11ff | 0x3130..=0x318f | 0xa960..=0xa97f | 0xac00..=0xd7af | 0xd7b0..=0xd7ff => {
            WritingSystem::Korean
        }
        0x0400..=0x052f | 0x1c80..=0x1c8f | 0x2de0..=0x2dff | 0xa640..=0xa69f => {
            WritingSystem::Cyrillic
        }
        0x0370..=0x03ff | 0x1f00..=0x1fff => WritingSystem::Greek,
        0x0600..=0x06ff | 0x0750..=0x077f | 0x08a0..=0x08ff | 0xfb50..=0xfdff | 0xfe70..=0xfeff => {
            WritingSystem::Arabic
        }
        _ => WritingSystem::Other,
    }
}

fn universal(text: &str) -> String {
    let mut romanized = String::new();
    for letter in text.chars() {
        match non_latin_letter(letter) {
            true => romanized.push_str(deunicode_char(letter).unwrap_or("")),
            false => romanized.push(letter),
        }
    }
    romanized
}

fn non_latin_letter(letter: char) -> bool {
    letter.is_alphabetic() && !latin(letter)
}

fn latin(letter: char) -> bool {
    matches!(
        letter as u32,
        0x0041..=0x024f | 0x1d00..=0x1eff | 0x2c60..=0x2c7f | 0xa720..=0xa7ff | 0xab30..=0xab6f
    )
}

fn tidy(text: &str) -> String {
    text.lines()
        .map(|line| line.split_whitespace().collect::<Vec<_>>().join(" "))
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn one(text: &str) -> String {
        lines(&[text.to_owned()]).remove(0)
    }

    #[test]
    fn romanizes_japanese_with_song_wide_script_detection() {
        let romanized = lines(&["こんにちは世界".to_owned(), "君のそばにいるよ".to_owned()]);
        assert_eq!(romanized[0], "konnichiwa sekai");
    }

    #[test]
    fn kanji_only_lines_follow_the_song_script() {
        let romanized = lines(&["世界".to_owned(), "こんにちは".to_owned()]);
        assert_eq!(romanized[0], "sekai");
    }

    #[test]
    fn romanizes_cyrillic_locally() {
        assert_eq!(one("Привет, мир!"), "Privet, mir!");
    }

    #[test]
    fn distinguishes_selectable_writing_systems() {
        let cases = [
            ("你好", WritingSystem::Chinese),
            ("안녕하세요", WritingSystem::Korean),
            ("Γειά", WritingSystem::Greek),
            ("مرحبا", WritingSystem::Arabic),
            ("שלום", WritingSystem::Other),
        ];
        for (text, expected) in cases {
            assert_eq!(detect(std::iter::once(text)), Some(expected));
        }
    }

    #[test]
    fn latin_lyrics_do_not_get_a_duplicate_line() {
        assert_eq!(one("Déjà vu"), "");
        assert_eq!(lines(&["hello".to_owned(), "world".to_owned()]), vec!["", ""]);
    }
}
