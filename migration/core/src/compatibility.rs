use std::collections::HashMap;
use std::sync::OnceLock;

pub fn correction(character: char) -> Vec<&'static str> {
    static TABLE: OnceLock<HashMap<char, Vec<&'static str>>> = OnceLock::new();
    TABLE
        .get_or_init(|| {
            let mut table: HashMap<char, Vec<&'static str>> = HashMap::new();
            for row in include_str!("../../data/bopomofo-correction.tsv").lines() {
                let (key, value) = row.split_once('\t').expect("validated correction table");
                let mut chars = key.chars();
                if let (Some(key), None) = (chars.next(), chars.next()) {
                    table.entry(key).or_default().push(value);
                }
            }
            table
        })
        .get(&character)
        .cloned()
        .unwrap_or_default()
}

// Match OVOFFullWidthCharacter, including its typographic quotes and brackets.
pub fn fullwidth(text: &str) -> String {
    text.chars()
        .map(|c| match c {
            ' ' => '\u{3000}',
            '"' => '”',
            '\'' => '’',
            '[' => '〔',
            ']' => '〕',
            '`' => '‘',
            '!'..='~' => char::from_u32(c as u32 + 0xfee0).unwrap(),
            _ => c,
        })
        .collect()
}

pub fn simplified(text: &str) -> String {
    static MAP: OnceLock<Vec<(u32, u32)>> = OnceLock::new();
    let map = MAP.get_or_init(|| {
        include_str!("../../data/tc2sc.tsv")
            .lines()
            .map(|row| {
                let (from, to) = row.split_once('\t').expect("validated conversion table");
                (
                    u32::from_str_radix(from, 16).unwrap(),
                    u32::from_str_radix(to, 16).unwrap(),
                )
            })
            .collect()
    });
    text.chars()
        .map(|c| {
            let mut base = 0;
            let mut count = map.len();
            // Preserve C bsearch, including the legacy array's implicit final zero pair.
            while count != 0 {
                let mid = base + count / 2;
                let (from, to) = map[mid];
                if c as u32 == from {
                    return char::from_u32(to)
                        .filter(|value| *value != '\0')
                        .unwrap_or(c);
                }
                if c as u32 > from {
                    base = mid + 1;
                    count -= 1;
                }
                count /= 2;
            }
            c
        })
        .collect()
}

pub fn associated(text: &str) -> Vec<&'static str> {
    if text.chars().count() != 1
        || !text
            .chars()
            .all(|c| (0x3000..=0xff00).contains(&(c as u32)))
    {
        return Vec::new();
    }
    static PHRASES: OnceLock<HashMap<&'static str, &'static str>> = OnceLock::new();
    PHRASES
        .get_or_init(|| {
            include_str!("../../data/associated-phrases.tsv")
                .lines()
                .map(|row| row.split_once('\t').expect("validated phrase table"))
                .collect()
        })
        .get(text)
        .map_or_else(Vec::new, |phrases| phrases.split(',').collect())
}

#[cfg(test)]
mod tests {
    #[test]
    fn fullwidth_matches_all_95_legacy_ascii_outputs_and_preserves_unicode() {
        let ascii: String = (32..=126).map(char::from).collect();
        let expected = "　！”＃＄％＆’（）＊＋，－．／０１２３４５６７８９：；＜＝＞？＠ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺ〔＼〕＾＿‘ａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ｛｜｝～";
        assert_eq!(super::fullwidth(&ascii), expected);
        assert_eq!(super::fullwidth("倉𨈍\n\t"), "倉𨈍\n\t");
    }

    #[test]
    fn every_initialized_conversion_pair_matches_the_original_filter_table() {
        for row in include_str!("../../data/tc2sc.tsv").lines() {
            let (from, to) = row.split_once('\t').unwrap();
            let from = char::from_u32(u32::from_str_radix(from, 16).unwrap()).unwrap();
            let to = char::from_u32(u32::from_str_radix(to, 16).unwrap()).unwrap();
            if from != '\0' {
                assert_eq!(super::simplified(&from.to_string()), to.to_string());
            }
        }
    }

    #[test]
    fn conversion_leaves_supplementary_unicode_and_phrase_order_intact() {
        assert_eq!(super::simplified("倉頡星𨈍"), "仓颉星𨈍");
        assert!(!super::associated("日").is_empty());
        assert!(super::associated("日期").is_empty());
        assert!(super::associated("a").is_empty());
    }
}
