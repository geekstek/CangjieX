use crate::{SIMPLEX_TABLE, TABLE, lookup_mode};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, OnceLock};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Key {
    Character(u8),
    Space,
    Return,
    Backspace,
    Escape,
    Up,
    Down,
    PageUp,
    PageDown,
    Left,
    Right,
    Other,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KeyEvent {
    pub key: Key,
    pub shift: bool,
    pub command: bool,
    pub control: bool,
    pub option: bool,
    pub caps_lock: bool,
}

impl KeyEvent {
    pub const fn new(key: Key) -> Self {
        Self {
            key,
            shift: false,
            command: false,
            control: false,
            option: false,
            caps_lock: false,
        }
    }
}

/// Immutable output for a single event. `committed` and `beep` are one-shot
/// effects; page/highlight are zero-based and highlight is relative to the page.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snapshot {
    pub handled: bool,
    pub reading: String,
    pub committed: String,
    pub beep: bool,
    pub visible: bool,
    pub page: usize,
    pub highlight: usize,
    pub candidates: Arc<[&'static str]>,
    pub learning: Option<(String, String, u64)>,
    pub associated: bool,
    pub per_page: usize,
    pub composing: String,
    pub cursor: usize,
    pub correction: bool,
}

/// Options mirror the legacy Cangjie settings. Default keeps the M1 profile.
#[derive(Clone, Copy, Debug)]
pub struct SessionOptions {
    pub compose_while_typing: bool,
    pub commit_at_maximum: bool,
    pub clear_on_error: bool,
    pub dynamic_frequency: bool,
    pub space_selects_first: bool,
    pub space_selects_one_page: bool,
    pub halfwidth_punctuation: bool,
    pub simplified_output: bool,
    pub associated_phrases: bool,
    pub fullwidth_output: bool,
    pub simplex: bool,
    pub bopomofo_correction: bool,
}

impl Default for SessionOptions {
    fn default() -> Self {
        Self {
            compose_while_typing: false,
            commit_at_maximum: false,
            clear_on_error: true,
            dynamic_frequency: false,
            space_selects_first: false,
            space_selects_one_page: true,
            halfwidth_punctuation: false,
            simplified_output: false,
            associated_phrases: false,
            fullwidth_output: false,
            simplex: false,
            bopomofo_correction: false,
        }
    }
}

type Frequencies = BTreeMap<String, Vec<(String, u64)>>;
#[derive(Clone, Debug, Default)]
pub struct Learning(Arc<Mutex<Frequencies>>);
impl Learning {
    pub fn set(&self, code: &str, text: &str, count: u64) {
        let mut data = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let rows = data.entry(code.to_owned()).or_default();
        if let Some(row) = rows.iter_mut().find(|row| row.0 == text) {
            row.1 = count;
        } else {
            rows.push((text.to_owned(), count));
        }
    }
    fn count(&self, code: &str, text: &str) -> u64 {
        self.0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(code)
            .and_then(|rows| rows.iter().find(|row| row.0 == text))
            .map_or(0, |row| row.1)
    }
    fn order(&self, code: &str, results: &mut Vec<&'static str>) {
        let data = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(rows) = data.get(code) {
            let mut rows = rows.clone();
            rows.sort_by_key(|row| std::cmp::Reverse(row.1));
            let mut ordered = Vec::new();
            for (text, count) in rows {
                if count > 0
                    && let Some(candidate) = results.iter().find(|candidate| **candidate == text)
                {
                    ordered.push(*candidate);
                }
            }
            results.retain(|text| !ordered.contains(text));
            ordered.append(results);
            *results = ordered;
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Session {
    code: String,
    candidates: Arc<[&'static str]>,
    page: usize,
    highlight: usize,
    options: SessionOptions,
    learning: Learning,
    learned: Option<(String, String, u64)>,
    associated: bool,
    correction: Option<(Vec<String>, usize)>,
}

impl Session {
    pub fn configured(options: SessionOptions, learning: Learning) -> Self {
        Self {
            options,
            learning,
            ..Self::default()
        }
    }
    pub fn import_frequency(&self, code: &str, text: &str, count: u64) {
        let valid = lookup_mode(code, self.options.simplex)
            .is_ok_and(|candidates| candidates.contains(&text))
            || include_str!("../../data/punctuation-halfwidth.tsv")
                .lines()
                .filter_map(|line| line.split_once('\t'))
                .any(|row| row == (code, text))
            || (!self.options.simplex
                && code.contains(['?', '*'])
                && TABLE.lines().filter_map(|line| line.split_once('\t')).any(
                    |(key, candidate)| {
                        candidate == text && wildcard_matches(code.as_bytes(), key.as_bytes())
                    },
                ));
        if valid {
            self.learning.set(code, text, count);
        }
    }
    /// Cancel input while retaining settings and learned order.
    pub fn reset(&mut self) {
        self.code.clear();
        self.close_candidates();
        self.learned = None;
        self.correction = None;
    }

    pub fn handle(&mut self, event: KeyEvent) -> Snapshot {
        self.learned = None;
        let mut committed = String::new();
        let mut beep = false;
        let was_correction = self.correction.is_some();
        // Shortcut behavior while composing was explicitly outside M1's
        // recorded profile. Preserve input and let the host handle shortcuts.
        let handled = if was_correction {
            self.handle_correction(event, &mut committed, &mut beep);
            true
        } else if event.command || event.control || event.option {
            false
        } else if self.associated {
            self.handle_associated(event, &mut committed, &mut beep)
        } else if !self.candidates.is_empty() {
            self.handle_candidates(event, &mut committed, &mut beep);
            true
        } else {
            self.handle_reading(event, &mut committed, &mut beep)
        };

        self.output(committed, handled, beep, !was_correction)
    }

    pub fn direct_text(&mut self, text: &str) -> Snapshot {
        self.learned = None;
        if !self.options.bopomofo_correction
            || !self.code.is_empty()
            || self.correction.is_some()
            || text.is_empty()
        {
            return self.output(String::new(), false, false, false);
        }
        self.reset();
        self.output(text.to_owned(), true, false, true)
    }

    fn output(
        &mut self,
        mut committed: String,
        handled: bool,
        beep: bool,
        allow_correction: bool,
    ) -> Snapshot {
        if allow_correction
            && self.options.bopomofo_correction
            && self.code.is_empty()
            && !committed.is_empty()
        {
            for (index, character) in committed.chars().enumerate() {
                let candidates = crate::compatibility::correction(character);
                if !candidates.is_empty() {
                    self.candidates = candidates.into();
                    self.page = 0;
                    self.highlight = 0;
                    self.associated = false;
                    self.correction =
                        Some((committed.chars().map(|c| c.to_string()).collect(), index));
                    committed.clear();
                    break;
                }
            }
        }

        if self.options.associated_phrases && self.code.is_empty() && !committed.is_empty() {
            let suggestions = crate::compatibility::associated(&committed);
            if !suggestions.is_empty() {
                self.candidates = suggestions.into();
                self.associated = true;
                self.page = 0;
                self.highlight = 9;
            }
        }
        if self.options.simplified_output {
            committed = crate::compatibility::simplified(&committed);
        }
        if self.options.fullwidth_output {
            committed = crate::compatibility::fullwidth(&committed);
        }
        Snapshot {
            handled,
            reading: self.code.bytes().filter_map(keyname).collect(),
            committed,
            beep,
            visible: !self.candidates.is_empty(),
            page: self.page,
            highlight: self.highlight,
            candidates: Arc::clone(&self.candidates),
            learning: self.learned.clone(),
            associated: self.associated,
            per_page: self.per_page(),
            composing: self
                .correction
                .as_ref()
                .map_or_else(String::new, |(characters, _)| characters.concat()),
            cursor: self.correction.as_ref().map_or(0, |(_, index)| *index),
            correction: self.correction.is_some(),
        }
    }

    fn handle_correction(&mut self, event: KeyEvent, committed: &mut String, beep: &mut bool) {
        if event.command || event.control || event.option || event.shift || event.caps_lock {
            *beep = true;
            return;
        }
        let choice = match event.key {
            Key::Escape => None,
            Key::Return => Some(self.page * 9 + self.highlight),
            Key::Character(c @ b'1'..=b'9') if usize::from(c - b'1') < self.page_size() => {
                Some(self.page * 9 + usize::from(c - b'1'))
            }
            Key::Up | Key::Down => {
                self.move_highlight(event.key == Key::Down, beep);
                return;
            }
            Key::PageUp | Key::Left => {
                self.move_page(false, beep);
                return;
            }
            Key::PageDown | Key::Right | Key::Space => {
                self.move_page(true, beep);
                return;
            }
            _ => {
                *beep = true;
                return;
            }
        };
        let (mut characters, index) = self.correction.take().expect("correction is active");
        if let Some(choice) = choice {
            characters[index] = self.candidates[choice].to_owned();
        }
        committed.push_str(&characters.concat());
        self.reset();
    }

    fn handle_reading(&mut self, event: KeyEvent, committed: &mut String, beep: &mut bool) -> bool {
        let printable = match event.key {
            Key::Character(character) if character.is_ascii_graphic() => Some(character),
            Key::Space => Some(b' '),
            _ => None,
        };
        if printable.is_none() && self.code.is_empty() {
            return false;
        }

        if event.caps_lock || (event.shift && printable.is_some_and(|c| c.is_ascii_alphabetic())) {
            self.reset();
            if let Some(character) = printable {
                let character = if event.caps_lock && event.shift {
                    character.to_ascii_uppercase()
                } else if character.is_ascii_uppercase() {
                    character.to_ascii_lowercase()
                } else {
                    character.to_ascii_uppercase()
                };
                committed.push(char::from(character));
            }
            return true;
        }

        match event.key {
            Key::Character(character) if keyname(character).is_some() => {
                if self.code.len() == self.maximum_radicals() {
                    *beep = true;
                } else {
                    self.append_radical(character, committed, beep);
                }
            }
            Key::Space | Key::Return => {
                if self.code.is_empty() {
                    committed.push(' ');
                } else {
                    self.compose(true, committed, beep);
                }
            }
            Key::Escape => self.reset(),
            Key::Backspace => {
                self.code.pop();
                if self.options.compose_while_typing {
                    self.compose(false, committed, beep);
                }
            }
            _ if self.code.is_empty() => {
                if let Some(character) = printable {
                    committed.push(char::from(character));
                } else {
                    return false;
                }
            }
            _ => {
                *beep = true;
                if printable.is_none() && self.options.compose_while_typing {
                    self.compose(
                        self.options.commit_at_maximum
                            && self.code.len() >= self.maximum_radicals(),
                        committed,
                        beep,
                    );
                }
            }
        }
        true
    }

    fn table(&self) -> &'static str {
        if self.options.simplex {
            SIMPLEX_TABLE
        } else {
            TABLE
        }
    }
    fn maximum_radicals(&self) -> usize {
        if self.options.simplex { 2 } else { 5 }
    }
    fn has_wildcard(&self) -> bool {
        !self.options.simplex && self.code.len() > 1 && self.code.contains(['?', '*'])
    }

    fn append_radical(&mut self, character: u8, committed: &mut String, beep: &mut bool) {
        self.code.push(char::from(character));
        let wildcard_tail =
            !self.options.simplex && self.code.len() > 1 && matches!(character, b'?' | b'*');
        if (!character.is_ascii_alphabetic()
            && !wildcard_tail
            && !(self.options.simplex && character == b'+'))
            || (self.options.commit_at_maximum && self.code.len() >= self.maximum_radicals())
        {
            self.compose(true, committed, beep);
        } else if self.options.compose_while_typing {
            self.compose(false, committed, beep);
        }
    }

    fn compose(&mut self, confirm: bool, committed: &mut String, beep: &mut bool) {
        let mut candidates: Vec<_> = if self.code.is_empty() {
            Vec::new()
        } else if self.has_wildcard() {
            // SQLite's un-ordered LIKE query in the recorded profile scans the
            // original rows. Keep that order, including duplicate candidates.
            self.table()
                .lines()
                .filter_map(|line| {
                    let (code, text) = line.split_once('\t').expect("validated embedded table");
                    wildcard_matches(self.code.as_bytes(), code.as_bytes()).then_some(text)
                })
                .collect()
        } else {
            lookup_mode(&self.code, self.options.simplex)
                .expect("session contains at most five ASCII radicals")
                .to_vec()
        };
        if self.options.halfwidth_punctuation && !(self.has_wildcard()) {
            let overrides: Vec<_> = include_str!("../../data/punctuation-halfwidth.tsv")
                .lines()
                .filter_map(|line| line.split_once('\t'))
                .filter_map(|(key, text)| (key == self.code).then_some(text))
                .collect();
            if !overrides.is_empty() {
                candidates = overrides;
            }
        }
        match candidates.as_slice() {
            [] => {
                self.close_candidates();
                if confirm {
                    *beep = true;
                }
                if self.options.clear_on_error && !self.options.compose_while_typing {
                    self.code.clear();
                }
            }
            [only] if confirm => {
                committed.push_str(only);
                self.reset();
            }
            _ => {
                if self.options.dynamic_frequency {
                    self.learning.order(&self.code, &mut candidates);
                }
                self.candidates = candidates.into();
                self.page = 0;
                self.highlight = 0;
            }
        }
    }

    fn handle_candidates(&mut self, event: KeyEvent, committed: &mut String, beep: &mut bool) {
        if !event.shift && !event.caps_lock {
            match event.key {
                Key::Escape => {
                    self.reset();
                    return;
                }
                Key::Return => {
                    self.choose(self.page * self.per_page() + self.highlight, committed);
                    return;
                }
                Key::Character(character @ b'1'..=b'9') => {
                    let offset = usize::from(character - b'1')
                        + usize::from(self.options.space_selects_first);
                    if offset < self.page_size() {
                        self.choose(self.page * self.per_page() + offset, committed);
                    } else {
                        *beep = true;
                    }
                    return;
                }
                Key::Up | Key::Down => {
                    self.move_highlight(event.key == Key::Down, beep);
                    return;
                }
                Key::PageUp | Key::Left => {
                    self.move_page(false, beep);
                    return;
                }
                Key::PageDown | Key::Right => {
                    self.move_page(true, beep);
                    return;
                }
                Key::Space if self.options.space_selects_first => {
                    self.choose(self.page * self.per_page(), committed);
                    return;
                }
                Key::Space
                    if self.candidates.len() > self.per_page()
                        || !self.options.space_selects_one_page =>
                {
                    self.move_page(true, beep);
                    return;
                }
                _ => {}
            }
        }
        if event.shift && matches!(event.key, Key::Character(b'<' | b'>')) {
            self.move_page(event.key == Key::Character(b'>'), beep);
            return;
        }
        match event.key {
            Key::Backspace => {
                self.close_candidates();
                self.code.pop();
                if self.options.compose_while_typing {
                    self.compose(false, committed, beep);
                }
            }
            Key::Space => self.choose(0, committed),
            Key::Character(character) if keyname(character).is_some() => {
                if self.options.compose_while_typing && self.code.len() < self.maximum_radicals() {
                    self.append_radical(character, committed, beep);
                } else {
                    // Legacy commits the current choice before starting the next code at overflow.
                    committed
                        .push_str(self.candidates[self.page * self.per_page() + self.highlight]);
                    self.reset();
                    self.code.push(char::from(character));
                    if !character.is_ascii_alphabetic() {
                        self.compose(true, committed, beep);
                    }
                }
            }
            _ => *beep = true,
        }
    }

    fn handle_associated(
        &mut self,
        event: KeyEvent,
        committed: &mut String,
        beep: &mut bool,
    ) -> bool {
        match event.key {
            Key::PageUp | Key::PageDown | Key::Space => {
                self.move_page(event.key != Key::PageUp, beep);
                self.highlight = 9;
                *beep = false;
                return true;
            }
            Key::Character(c) if event.shift => {
                if let Some(index) = b"!@#$%^&*(".iter().position(|key| *key == c) {
                    if index < self.page_size() {
                        committed.push_str(self.candidates[self.page * self.per_page() + index]);
                    } else {
                        *beep = true;
                    }
                    self.reset();
                    return true;
                }
            }
            _ => {}
        }
        self.reset();
        if matches!(event.key, Key::Return | Key::Escape) {
            true
        } else {
            self.handle_reading(event, committed, beep)
        }
    }

    fn choose(&mut self, index: usize, committed: &mut String) {
        let text = self.candidates[index];
        let learned = if self.options.dynamic_frequency && index != 0 {
            let count = self.learning.count(&self.code, text).saturating_add(1);
            self.learning.set(&self.code, text, count);
            Some((self.code.clone(), text.to_owned(), count))
        } else {
            None
        };
        committed.push_str(text);
        self.reset();
        self.learned = learned;
    }

    fn close_candidates(&mut self) {
        self.candidates = Arc::default();
        self.associated = false;
        self.page = 0;
        self.highlight = 0;
    }

    fn per_page(&self) -> usize {
        if self.associated || self.correction.is_some() {
            return 9;
        }
        self.candidates
            .len()
            .min(if self.options.space_selects_first {
                10
            } else {
                9
            })
    }

    fn page_size(&self) -> usize {
        (self.candidates.len() - self.page * self.per_page()).min(self.per_page())
    }

    fn move_page(&mut self, forward: bool, beep: &mut bool) {
        let pages = self.candidates.len().div_ceil(self.per_page());
        let old_page = self.page;
        self.page = if forward {
            (self.page + 1) % pages
        } else {
            (self.page + pages - 1) % pages
        };
        self.highlight = 0;
        *beep = self.page == old_page;
    }

    fn move_highlight(&mut self, forward: bool, beep: &mut bool) {
        if forward && self.highlight + 1 < self.page_size() {
            self.highlight += 1;
        } else if !forward && self.highlight > 0 {
            self.highlight -= 1;
        } else {
            let old_highlight = self.highlight;
            self.move_page(forward, beep);
            if *beep {
                self.highlight = old_highlight;
            } else if !forward {
                self.highlight = self.page_size() - 1;
            }
        }
    }
}

fn keyname(character: u8) -> Option<&'static str> {
    static NAMES: OnceLock<[Option<&'static str>; 128]> = OnceLock::new();
    NAMES
        .get_or_init(|| {
            let mut names = [None; 128];
            for row in include_str!("../../data/keynames.tsv").lines() {
                let (code, name) = row.split_once('\t').expect("validated keynames");
                names[usize::from(code.as_bytes()[0])] = Some(name);
            }
            names
        })
        .get(usize::from(character))
        .copied()
        .flatten()
}

fn wildcard_matches(pattern: &[u8], code: &[u8]) -> bool {
    let mut previous = [false; 6];
    previous[0] = true;
    for token in pattern {
        let mut current = [false; 6];
        current[0] = *token == b'*' && previous[0];
        for (index, character) in code.iter().enumerate() {
            current[index + 1] = if *token == b'*' {
                previous[index + 1] || current[index]
            } else {
                previous[index] && (*token == b'?' || token == character)
            };
        }
        previous = current;
    }
    previous[code.len()]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn type_code(session: &mut Session, code: &str) {
        for character in code.bytes() {
            session.handle(KeyEvent::new(Key::Character(character)));
        }
    }

    #[test]
    fn correction_preserves_pending_reading_and_uses_output_filters_after_selection() {
        let mut session = Session::configured(
            SessionOptions {
                bopomofo_correction: true,
                simplified_output: true,
                fullwidth_output: true,
                ..SessionOptions::default()
            },
            Learning::default(),
        );
        type_code(&mut session, "a");
        let blocked = session.direct_text("ㄇ");
        assert!(!blocked.handled);
        assert_eq!(blocked.reading, "日");
        session.reset();
        let pending = session.direct_text("𨈍ㄇ2");
        assert_eq!(pending.composing, "𨈍ㄇ2");
        assert_eq!(pending.cursor, 1);
        assert!(pending.correction);
        assert!(pending.learning.is_none());
        let chosen = session.handle(KeyEvent::new(Key::Character(b'1')));
        assert_eq!(chosen.committed, "𨈍吗２");
        assert!(!chosen.correction);
        assert!(chosen.composing.is_empty());
        assert_eq!(pending.composing, "𨈍ㄇ2");
        assert!(!Session::default().direct_text("ㄅ").handled);
    }

    #[test]
    fn fullwidth_is_an_output_filter_and_leaves_reading_selection_and_shortcuts_intact() {
        let mut session = Session::configured(
            SessionOptions {
                fullwidth_output: true,
                compose_while_typing: true,
                halfwidth_punctuation: true,
                ..SessionOptions::default()
            },
            Learning::default(),
        );
        let reading = session.handle(KeyEvent::new(Key::Character(b'a')));
        assert_eq!(reading.reading, "日");
        assert_eq!(reading.candidates.as_ref(), ["日", "曰"]);
        let shortcut = session.handle(KeyEvent {
            command: true,
            ..KeyEvent::new(Key::Character(b'c'))
        });
        assert!(!shortcut.handled);
        assert_eq!(shortcut.reading, "日");
        assert_eq!(
            session
                .handle(KeyEvent::new(Key::Character(b'2')))
                .committed,
            "曰"
        );
        assert_eq!(
            session
                .handle(KeyEvent::new(Key::Character(b'2')))
                .committed,
            "２"
        );
        assert_eq!(session.handle(KeyEvent::new(Key::Space)).committed, "　");
        assert_eq!(
            session
                .handle(KeyEvent::new(Key::Character(b',')))
                .committed,
            "，"
        );
        assert_eq!(
            session
                .handle(KeyEvent {
                    shift: true,
                    ..KeyEvent::new(Key::Character(b'a'))
                })
                .committed,
            "Ａ"
        );
    }

    #[test]
    fn live_settings_and_learning_survive_reset_without_changing_reference_defaults() {
        let mut session = Session::configured(
            SessionOptions {
                compose_while_typing: true,
                commit_at_maximum: true,
                clear_on_error: false,
                dynamic_frequency: true,
                halfwidth_punctuation: true,
                ..SessionOptions::default()
            },
            Learning::default(),
        );
        let first = session.handle(KeyEvent::new(Key::Character(b'a')));
        assert_eq!(first.candidates.as_ref(), ["日", "曰"]);
        let selected = session.handle(KeyEvent::new(Key::Character(b'2')));
        assert_eq!(selected.learning, Some(("a".into(), "曰".into(), 1)));
        session.reset();
        assert_eq!(
            session
                .handle(KeyEvent::new(Key::Character(b'a')))
                .candidates
                .as_ref(),
            ["曰", "日"]
        );
        session.reset();
        type_code(&mut session, "rvbce");
        assert!(!session.handle(KeyEvent::new(Key::Return)).handled);
        assert_eq!(
            session
                .handle(KeyEvent::new(Key::Character(b',')))
                .committed,
            ","
        );
        let mut reference = Session::default();
        assert!(
            !reference
                .handle(KeyEvent::new(Key::Character(b'a')))
                .visible
        );
    }

    #[test]
    fn phrase_hints_do_not_use_plain_number_selection_or_become_pending_reading() {
        let mut session = Session::configured(
            SessionOptions {
                compose_while_typing: true,
                simplified_output: true,
                associated_phrases: true,
                ..SessionOptions::default()
            },
            Learning::default(),
        );
        type_code(&mut session, "oiar");
        let snapshot = session.handle(KeyEvent::new(Key::Space));
        assert_eq!(snapshot.committed, "仓");
        assert!(snapshot.associated && snapshot.reading.is_empty());
        assert_eq!(snapshot.per_page, 9);
        let plain = session.handle(KeyEvent::new(Key::Character(b'2')));
        assert_eq!(plain.committed, "2");
        assert!(!plain.visible);
        type_code(&mut session, "a");
        let committed = session.handle(KeyEvent::new(Key::Character(b'1')));
        assert!(committed.associated);
        let chosen = session.handle(KeyEvent {
            shift: true,
            ..KeyEvent::new(Key::Character(b'!'))
        });
        assert_eq!(chosen.committed, "本");
        assert!(!chosen.beep);
        let dismissed = session.handle(KeyEvent::new(Key::Escape));
        assert!(dismissed.handled && !dismissed.visible);
    }

    #[test]
    fn sessions_and_retained_snapshots_are_independent() {
        let mut first = Session::default();
        let mut second = Session::default();
        type_code(&mut first, "a");
        let retained = first.handle(KeyEvent::new(Key::Space));
        type_code(&mut second, "rvbce");
        first.reset();
        assert_eq!(retained.reading, "日");
        assert_eq!(retained.candidates.as_ref(), ["日", "曰"]);
        assert_eq!(second.handle(KeyEvent::new(Key::Space)).committed, "𨈍");
        assert!(!first.handle(KeyEvent::new(Key::Backspace)).handled);
    }

    #[test]
    fn effects_do_not_repeat_and_reset_cancels_pending_candidates() {
        let mut session = Session::default();
        type_code(&mut session, "a");
        session.handle(KeyEvent::new(Key::Space));
        assert_eq!(session.handle(KeyEvent::new(Key::Return)).committed, "日");
        let next = session.handle(KeyEvent::new(Key::Return));
        assert!(!next.handled);
        assert!(next.committed.is_empty());
        type_code(&mut session, "a");
        session.handle(KeyEvent::new(Key::Space));
        session.reset();
        let next = session.handle(KeyEvent::new(Key::Other));
        assert!(!next.handled && !next.visible && !next.beep);
        assert!(next.reading.is_empty() && next.candidates.is_empty());
    }

    #[test]
    fn shortcuts_preserve_composition_and_candidate_selection() {
        let mut session = Session::default();
        type_code(&mut session, "a");
        session.handle(KeyEvent::new(Key::Space));
        for event in [
            KeyEvent {
                command: true,
                ..KeyEvent::new(Key::Character(b'a'))
            },
            KeyEvent {
                control: true,
                ..KeyEvent::new(Key::Character(b'a'))
            },
            KeyEvent {
                option: true,
                ..KeyEvent::new(Key::Character(b'a'))
            },
        ] {
            let snapshot = session.handle(event);
            assert!(!snapshot.handled && snapshot.visible && !snapshot.beep);
            assert_eq!(snapshot.reading, "日");
            assert!(snapshot.committed.is_empty());
        }
        assert_eq!(
            session
                .handle(KeyEvent::new(Key::Character(b'2')))
                .committed,
            "曰"
        );
    }

    #[test]
    fn candidate_backspace_edits_reading_and_space_chooses_first_despite_highlight() {
        let mut session = Session::default();
        type_code(&mut session, "ab");
        session.handle(KeyEvent::new(Key::Space));
        let snapshot = session.handle(KeyEvent::new(Key::Backspace));
        assert_eq!(snapshot.reading, "日");
        assert!(!snapshot.visible && snapshot.committed.is_empty());
        session.handle(KeyEvent::new(Key::Space));
        session.handle(KeyEvent::new(Key::Down));
        assert_eq!(session.handle(KeyEvent::new(Key::Space)).committed, "日");
    }

    #[test]
    fn one_event_can_commit_a_candidate_and_punctuation_without_losing_either() {
        let mut session = Session::default();
        type_code(&mut session, "a");
        session.handle(KeyEvent::new(Key::Space));
        let snapshot = session.handle(KeyEvent::new(Key::Character(b',')));
        assert_eq!(snapshot.committed, "日，");
        assert!(snapshot.reading.is_empty() && !snapshot.visible);
    }

    #[test]
    fn wrapping_pages_and_highlights_stay_within_the_current_page() {
        let mut session = Session::default();
        type_code(&mut session, "ddp");
        session.handle(KeyEvent::new(Key::Space));
        let snapshot = session.handle(KeyEvent::new(Key::Up));
        assert_eq!((snapshot.page, snapshot.highlight), (1, 3));
        let snapshot = session.handle(KeyEvent::new(Key::Down));
        assert_eq!((snapshot.page, snapshot.highlight), (0, 0));
        let snapshot = session.handle(KeyEvent::new(Key::Left));
        assert_eq!((snapshot.page, snapshot.highlight), (1, 0));
        let snapshot = session.handle(KeyEvent::new(Key::Right));
        assert_eq!((snapshot.page, snapshot.highlight), (0, 0));
    }

    #[test]
    fn wildcard_composition_and_literal_wildcard_punctuation_are_distinct() {
        let mut session = Session::default();
        type_code(&mut session, "rvbc?");
        let snapshot = session.handle(KeyEvent::new(Key::Space));
        assert_eq!(snapshot.candidates.as_ref(), ["𨆎", "𨈍"]);
        assert_eq!(
            session
                .handle(KeyEvent::new(Key::Character(b'2')))
                .committed,
            "𨈍"
        );
        assert_eq!(
            session
                .handle(KeyEvent::new(Key::Character(b'?')))
                .committed,
            "？"
        );
        for (pattern, code, expected) in [
            ("a?", "aa", true),
            ("a?", "aaa", false),
            ("a*", "a", true),
            ("a**?", "ab", true),
            ("a*b", "ac", false),
        ] {
            assert_eq!(
                wildcard_matches(pattern.as_bytes(), code.as_bytes()),
                expected
            );
        }
    }

    #[test]
    fn five_radicals_are_kept_on_overflow_and_cleared_on_failed_composition() {
        let mut session = Session::default();
        type_code(&mut session, "aaaaa");
        let overflow = session.handle(KeyEvent::new(Key::Character(b'a')));
        assert!(overflow.handled && overflow.beep && !overflow.visible);
        assert_eq!(overflow.reading, "日日日日日");
        let failed = session.handle(KeyEvent::new(Key::Return));
        assert!(failed.beep && failed.reading.is_empty() && failed.committed.is_empty());
        type_code(&mut session, "mfmff");
        assert_eq!(session.handle(KeyEvent::new(Key::Space)).committed, "厵");
    }

    #[test]
    fn digits_select_only_open_candidates_on_the_current_page() {
        let mut session = Session::default();
        type_code(&mut session, "a");
        let digit = session.handle(KeyEvent::new(Key::Character(b'1')));
        assert!(digit.beep && digit.committed.is_empty());
        assert_eq!(digit.reading, "日");
        session.handle(KeyEvent::new(Key::Space));
        assert_eq!(
            session
                .handle(KeyEvent::new(Key::Character(b'2')))
                .committed,
            "曰"
        );
        type_code(&mut session, "ddp");
        let all = session.handle(KeyEvent::new(Key::Space)).candidates;
        session.handle(KeyEvent::new(Key::PageDown));
        let invalid = session.handle(KeyEvent::new(Key::Character(b'9')));
        assert!(invalid.beep && invalid.visible && invalid.committed.is_empty());
        assert_eq!(
            session
                .handle(KeyEvent::new(Key::Character(b'1')))
                .committed,
            all[9]
        );
    }

    #[test]
    fn empty_controls_pass_through_and_shift_commits_english() {
        let mut session = Session::default();
        for key in [Key::Return, Key::Backspace, Key::Escape, Key::Other] {
            assert!(!session.handle(KeyEvent::new(key)).handled);
        }
        assert_eq!(session.handle(KeyEvent::new(Key::Space)).committed, " ");
        type_code(&mut session, "a");
        let english = session.handle(KeyEvent {
            shift: true,
            ..KeyEvent::new(Key::Character(b'a'))
        });
        assert_eq!(english.committed, "A");
        assert!(english.reading.is_empty());
    }

    #[test]
    fn caps_lock_respects_received_case_and_clears_reading() {
        let mut session = Session::default();
        for (character, shift, expected) in
            [(b'a', false, "A"), (b'A', false, "a"), (b'a', true, "A")]
        {
            type_code(&mut session, "ab");
            let snapshot = session.handle(KeyEvent {
                caps_lock: true,
                shift,
                ..KeyEvent::new(Key::Character(character))
            });
            assert_eq!(snapshot.committed, expected);
            assert!(snapshot.reading.is_empty() && !snapshot.visible);
        }
    }
}
