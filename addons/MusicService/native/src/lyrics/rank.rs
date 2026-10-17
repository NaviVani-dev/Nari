use std::collections::HashSet;
use std::time::Duration;

use super::Line;

const CLOSE_ENOUGH: u64 = 3;
const WAY_OFF: u64 = 10;
const TITLE: i64 = 40;
const ARTIST: i64 = 30;
const ALBUM: i64 = 15;
const SYNCED: i64 = 200;
const WORDED: i64 = 400;
const DRIFTED: i64 = 50;
const TRUNCATED: i64 = 500;
const TRUSTED: u32 = 25;

pub struct Query {
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
    pub duration: Duration,
}

pub struct Hit {
    pub trust: u32,
    pub provider: String,
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
    pub duration: Option<Duration>,
    pub synced: bool,
    pub text: String,
    pub lines: Vec<Line>,
}

impl Hit {
    fn worded(&self) -> bool {
        self.synced && self.lines.iter().any(Line::worded)
    }

    fn is_empty(&self) -> bool {
        match self.synced {
            true => self.lines.is_empty(),
            false => self.text.trim().is_empty(),
        }
    }

    fn span(&self) -> Option<Duration> {
        self.synced
            .then(|| self.lines.iter().map(|line| line.end.unwrap_or(line.start)).max())
            .flatten()
    }

    fn texts(&self) -> impl Iterator<Item = String> + '_ {
        self.lines.iter().flat_map(|line| {
            let background: String = line.background.iter().map(|word| word.text.as_str()).collect();
            std::iter::once(line.text.clone()).chain((!background.trim().is_empty()).then_some(background))
        })
    }
}

pub fn ordered(query: &Query, hits: &[Hit]) -> (Vec<usize>, Vec<(usize, Vec<Line>)>) {
    let mut scored: Vec<(i64, usize)> = hits
        .iter()
        .enumerate()
        .filter(|(_, hit)| eligible(query, hit))
        .map(|(index, hit)| (score(query, hit), index))
        .collect();
    scored.sort_by(|(left_score, left), (right_score, right)| {
        right_score
            .cmp(left_score)
            .then_with(|| hits[*left].provider.cmp(&hits[*right].provider))
            .then_with(|| hits[*left].title.cmp(&hits[*right].title))
    });
    let mut seen = HashSet::new();
    let order: Vec<usize> = scored
        .into_iter()
        .map(|(_, index)| index)
        .filter(|index| seen.insert(fingerprint(&hits[*index])))
        .collect();

    let guide = order
        .iter()
        .map(|index| &hits[*index])
        .find(|hit| hit.synced && !hit.worded());
    let reshaped = match guide {
        None => Vec::new(),
        Some(guide) => order
            .iter()
            .filter(|index| {
                let hit = &hits[**index];
                hit.worded() && hit.trust < TRUSTED && !layered(&hit.lines)
            })
            .filter_map(|index| {
                super::shape::conform(&hits[*index].lines, &guide.lines).map(|lines| (*index, lines))
            })
            .collect(),
    };
    (order, reshaped)
}

fn layered(lines: &[Line]) -> bool {
    lines.iter().any(|line| !line.background.is_empty() || !line.lead)
}

fn eligible(query: &Query, hit: &Hit) -> bool {
    matched(query, hit) && !hit.is_empty() && !low_quality(hit)
}

fn matched(query: &Query, hit: &Hit) -> bool {
    if !alike(&hit.title, &query.title) || !artists_alike(&hit.artist, &query.artist) {
        return false;
    }
    hit.duration.is_none_or(|duration| {
        query.duration.is_zero() || duration.as_secs().abs_diff(query.duration.as_secs()) <= WAY_OFF
    })
}

fn score(query: &Query, hit: &Hit) -> i64 {
    let mut score = i64::from(hit.trust);
    if let Some(duration) = hit.duration {
        let drift = duration.as_secs().abs_diff(query.duration.as_secs());
        if drift <= CLOSE_ENOUGH {
            score += 100 - drift as i64 * 10;
        } else if drift > WAY_OFF {
            score -= DRIFTED;
        }
    }
    if alike(&hit.title, &query.title) {
        score += TITLE;
    }
    if artists_alike(&hit.artist, &query.artist) {
        score += ARTIST;
    }
    if let (Some(album), Some(named)) = (&query.album, &hit.album) {
        if alike(named, album) {
            score += ALBUM;
        }
    }
    if hit.synced {
        score += SYNCED;
    }
    if hit.worded() {
        score += WORDED;
    }
    if truncated(hit, query.duration) {
        score -= TRUNCATED;
    }
    score
}

fn truncated(hit: &Hit, duration: Duration) -> bool {
    let Some(span) = hit.span() else {
        return false;
    };
    !duration.is_zero() && span.as_secs_f64() < duration.as_secs_f64() * 0.6
}

fn low_quality(hit: &Hit) -> bool {
    if !hit.synced {
        return false;
    }
    let (total, noisy) = hit.texts().fold((0usize, 0usize), |(total, noisy), text| {
        (total + 1, noisy + usize::from(stretched_shout(&text)))
    });
    noisy >= 3 && noisy.saturating_mul(6) >= total
}

fn stretched_shout(text: &str) -> bool {
    let mut uppercase = false;
    let mut lowercase = false;
    let mut previous = None;
    let mut run = 0usize;
    let mut longest = 0usize;
    for letter in text.chars().filter(|letter| letter.is_alphabetic()) {
        uppercase |= letter.is_uppercase();
        lowercase |= letter.is_lowercase();
        let folded = letter.to_lowercase().next().unwrap_or(letter);
        if previous == Some(folded) {
            run += 1;
        } else {
            previous = Some(folded);
            run = 1;
        }
        longest = longest.max(run);
    }
    uppercase && !lowercase && longest >= 3
}

fn fingerprint(hit: &Hit) -> String {
    let trim = |text: &str| {
        text.chars()
            .filter(|letter| letter.is_alphanumeric())
            .flat_map(char::to_lowercase)
            .collect::<String>()
    };
    match hit.synced {
        false => format!("plain:{}", trim(&hit.text)),
        true => {
            let text: String = hit.texts().map(|text| trim(&text)).collect();
            format!("synced:{}:{text}", hit.worded())
        }
    }
}

fn alike(left: &str, right: &str) -> bool {
    let (left, right) = (undecorated(left), undecorated(right));
    if left.is_empty() || right.is_empty() {
        return false;
    }
    if left == right {
        return true;
    }
    let (short, long) = match left.len() <= right.len() {
        true => (&left, &right),
        false => (&right, &left),
    };
    long.contains(short.as_str()) && short.len() * 2 >= long.len()
}

fn artists_alike(left: &str, right: &str) -> bool {
    alike(left, right)
        || artist_names(left).any(|left| artist_names(right).any(|right| alike(left, right)))
}

fn artist_names(artists: &str) -> impl Iterator<Item = &str> {
    artists
        .split([',', '&', ';'])
        .map(str::trim)
        .filter(|artist| !artist.is_empty())
}

pub(super) fn undecorated(text: &str) -> String {
    let text = text.split(" - ").next().unwrap_or(text);
    let mut depth = 0usize;
    text.chars()
        .filter(|letter| match letter {
            '(' | '[' => {
                depth += 1;
                false
            }
            ')' | ']' => {
                depth = depth.saturating_sub(1);
                false
            }
            _ => depth == 0,
        })
        .filter(|letter| letter.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(start: u64, text: &str, words: &[(u64, &str)]) -> Line {
        Line {
            start: Duration::from_millis(start),
            end: Some(Duration::from_millis(start + 2000)),
            text: text.to_owned(),
            words: words
                .iter()
                .map(|(at, word)| super::super::Word {
                    start: Duration::from_millis(*at),
                    end: Duration::from_millis(at + 400),
                    text: (*word).to_owned(),
                })
                .collect(),
            background: Vec::new(),
            lead: true,
        }
    }

    fn hit(provider: &str, trust: u32, synced: bool, lines: Vec<Line>) -> Hit {
        Hit {
            trust,
            provider: provider.to_owned(),
            title: "Idol".to_owned(),
            artist: "YOASOBI".to_owned(),
            album: None,
            duration: Some(Duration::from_secs(213)),
            synced,
            text: lines.iter().map(|line| line.text.clone()).collect::<Vec<_>>().join("\n"),
            lines,
        }
    }

    fn query() -> Query {
        Query {
            title: "Idol".to_owned(),
            artist: "YOASOBI".to_owned(),
            album: None,
            duration: Duration::from_secs(213),
        }
    }

    fn song(words: bool) -> Vec<Line> {
        (0..70)
            .map(|index| {
                let start = index * 3000;
                match words {
                    true => line(start, &format!("line {index} here"), &[(start, "line "), (start + 400, &format!("{index} ")), (start + 800, "here")]),
                    false => line(start, &format!("line {index} here"), &[]),
                }
            })
            .collect()
    }

    #[test]
    fn worded_lyrics_beat_line_synced_and_plain() {
        let hits = vec![
            hit("LrcLib", 0, false, song(false)),
            hit("Musixmatch", 35, true, song(false)),
            hit("Apple Music", 180, true, song(true)),
        ];
        let (order, _) = ordered(&query(), &hits);
        assert_eq!(order, vec![2, 1, 0]);
    }

    #[test]
    fn other_songs_and_duplicates_are_dropped() {
        let mut other = hit("NetEase", 0, true, song(false));
        other.title = "Racing into the Night".to_owned();
        let hits = vec![hit("Musixmatch", 35, true, song(false)), hit("LrcLib", 0, true, song(false)), other];
        let (order, _) = ordered(&query(), &hits);
        assert_eq!(order, vec![0]);
    }

    #[test]
    fn decorations_do_not_break_title_matching() {
        assert!(alike("Idol (Official Audio)", "Idol"));
        assert!(artists_alike("YOASOBI, Ayase", "YOASOBI"));
        assert!(!alike("Idol", "Idolatry of the Machine Empire"));
    }
}
