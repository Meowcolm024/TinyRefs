use std::collections::BTreeMap;
use std::fmt::Write;

use biblatex::{
    Bibliography, Chunk, ChunksExt, Date, DateValue, Datetime, Entry, EntryType, Person, Spanned,
};
use serde::Serialize;

use crate::{import::MONTH_NAMES, reference::Reference};

#[derive(Serialize)]
pub(crate) struct StructuredReference<'a> {
    #[serde(flatten)]
    reference: &'a Reference,
    structured: StructuredFields,
}

impl<'a> StructuredReference<'a> {
    pub fn new(reference: &'a Reference, fields: &BTreeMap<String, String>) -> Self {
        Self {
            reference,
            structured: StructuredFields::from_fields(fields),
        }
    }
}

#[derive(Serialize)]
struct StructuredFields {
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
    authors: Vec<Name>,
    editors: Vec<Name>,
    #[serde(skip_serializing_if = "Option::is_none")]
    date: Option<PublicationDate>,
    #[serde(skip_serializing_if = "Option::is_none")]
    event_date: Option<PublicationDate>,
    #[serde(skip_serializing_if = "Option::is_none")]
    original_date: Option<PublicationDate>,
    #[serde(skip_serializing_if = "Option::is_none")]
    access_date: Option<PublicationDate>,
    keywords: Vec<String>,
    #[serde(rename = "abstract", skip_serializing_if = "Option::is_none")]
    abstract_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    container_title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    publisher: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    doi: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    url: Option<String>,
}

impl StructuredFields {
    fn from_fields(fields: &BTreeMap<String, String>) -> Self {
        let entry = parsed_fields(fields);
        let text = |name| field_text(&entry, name);
        Self {
            title: text("title"),
            authors: names(&entry, "author"),
            editors: names(&entry, "editor"),
            date: text("date")
                .or_else(|| legacy_date(&entry))
                .map(PublicationDate::parse),
            event_date: text("eventdate").map(PublicationDate::parse),
            original_date: text("origdate").map(PublicationDate::parse),
            access_date: text("urldate").map(PublicationDate::parse),
            keywords: entry
                .get_as::<Vec<String>>("keywords")
                .unwrap_or_default()
                .into_iter()
                .filter_map(|keyword| display_text(&keyword))
                .collect(),
            abstract_text: text("abstract"),
            container_title: text("journaltitle")
                .or_else(|| text("journal"))
                .or_else(|| text("booktitle")),
            publisher: text("publisher"),
            doi: text("doi"),
            url: text("url"),
        }
    }
}

fn parsed_fields(fields: &BTreeMap<String, String>) -> Entry {
    const KNOWN: &[&str] = &[
        "title",
        "author",
        "editor",
        "date",
        "year",
        "month",
        "day",
        "eventdate",
        "origdate",
        "urldate",
        "keywords",
        "abstract",
        "journaltitle",
        "journal",
        "booktitle",
        "publisher",
        "doi",
        "url",
    ];
    let fields: Vec<_> = KNOWN
        .iter()
        .filter_map(|&name| {
            let expression = fields.get(name)?;
            can_decode_tex(expression).then_some((name, expression))
        })
        .collect();
    let mut source = String::from("@misc{metadata,\n");
    for (name, expression) in &fields {
        let _ = writeln!(source, "{name} = {expression},");
    }
    source.push('}');
    if let Some(entry) = parse_entry(&source) {
        return entry;
    }

    // A field with unsupported TeX markup can fail text decoding. Keep the other fields.
    let mut entry = Entry::new("metadata".into(), EntryType::Misc);
    for (name, expression) in fields {
        if let Some(parsed) = parse_entry(&format!("@misc{{metadata, {name} = {expression}}}")) {
            entry.fields.extend(parsed.fields);
        }
    }
    entry
}

fn can_decode_tex(expression: &str) -> bool {
    // The high-level parser decodes command arguments recursively.
    let mut depth = 0usize;
    let mut characters = expression.chars();
    while let Some(character) = characters.next() {
        match character {
            '\\' => {
                characters.next();
            }
            '{' => {
                depth += 1;
                if depth > 64 {
                    return false;
                }
            }
            '}' if depth == 0 => return false,
            '}' => depth -= 1,
            _ => {}
        }
    }
    depth == 0
}

fn parse_entry(source: &str) -> Option<Entry> {
    Bibliography::parse(source).ok()?.into_vec().pop()
}

fn field_text(entry: &Entry, name: &str) -> Option<String> {
    display_text(&entry.get(name)?.format_verbatim())
}

fn display_text(text: &str) -> Option<String> {
    // Bibliography exports from publishers can contain HTML entities in their text fields.
    let mut decoded = String::new();
    for part in text.split_inclusive(';') {
        if let Some((prefix, entity)) = part
            .strip_suffix(';')
            .and_then(|part| part.rsplit_once('&'))
            && let Some(character) = entity_character(entity)
        {
            decoded.push_str(prefix);
            decoded.push(character);
        } else {
            decoded.push_str(part);
        }
    }
    let text = decoded.split_whitespace().collect::<Vec<_>>().join(" ");
    (!text.is_empty()).then_some(text)
}

fn entity_character(entity: &str) -> Option<char> {
    Some(match entity {
        "nbsp" => '\u{a0}',
        "amp" => '&',
        "lt" => '<',
        "gt" => '>',
        "quot" => '"',
        "apos" => '\'',
        "ndash" => '–',
        "mdash" => '—',
        value => {
            let digits = value.strip_prefix('#')?;
            let code = if let Some(hex) = digits.strip_prefix(['x', 'X']) {
                u32::from_str_radix(hex, 16).ok()?
            } else {
                digits.parse().ok()?
            };
            char::from_u32(code)?
        }
    })
}

#[derive(Serialize)]
struct Name {
    given_name: String,
    family_name: String,
    prefix: String,
    suffix: String,
}

fn names(entry: &Entry, field: &str) -> Vec<Name> {
    entry
        .get_as::<Vec<Person>>(field)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|person| {
            let name = Name {
                given_name: display_text(&person.given_name).unwrap_or_default(),
                family_name: display_text(&person.name).unwrap_or_default(),
                prefix: display_text(&person.prefix).unwrap_or_default(),
                suffix: display_text(&person.suffix).unwrap_or_default(),
            };
            (!name.given_name.is_empty()
                || !name.family_name.is_empty()
                || !name.prefix.is_empty()
                || !name.suffix.is_empty())
            .then_some(name)
        })
        .collect()
}

#[derive(Serialize)]
struct PublicationDate {
    text: String,
    kind: DateKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    start: Option<DateParts>,
    #[serde(skip_serializing_if = "Option::is_none")]
    end: Option<DateParts>,
    approximate: bool,
    uncertain: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
enum DateKind {
    Single,
    Range,
    After,
    Before,
    Unparsed,
}

#[derive(Serialize)]
struct DateParts {
    year: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    month: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    day: Option<u8>,
}

impl From<Datetime> for DateParts {
    fn from(date: Datetime) -> Self {
        Self {
            year: date.year,
            month: date.month.map(|month| month + 1),
            day: date.day.map(|day| day + 1),
        }
    }
}

impl PublicationDate {
    fn parse(text: String) -> Self {
        let mut result = Self {
            text,
            kind: DateKind::Unparsed,
            start: None,
            end: None,
            approximate: false,
            uncertain: false,
        };
        // biblatex 0.12's date parser can panic on malformed wildcard dates or non-ASCII digits.
        if result.text.contains(['x', 'X'])
            || result
                .text
                .chars()
                .any(|c| c.is_numeric() && !c.is_ascii_digit())
        {
            return result;
        }
        if let Ok(date) = Date::parse(&[Spanned::zero(Chunk::Normal(result.text.clone()))]) {
            (result.kind, result.start, result.end) = match date.value {
                DateValue::At(date) => (DateKind::Single, Some(date.into()), None),
                DateValue::Between(start, end) => {
                    (DateKind::Range, Some(start.into()), Some(end.into()))
                }
                DateValue::After(start) => (DateKind::After, Some(start.into()), None),
                DateValue::Before(end) => (DateKind::Before, None, Some(end.into())),
            };
            result.approximate = date.approximate;
            result.uncertain = date.uncertain;
        }
        result
    }
}

fn legacy_date(entry: &Entry) -> Option<String> {
    let year = field_text(entry, "year")?;
    let Ok(number) = year.parse::<i32>() else {
        return Some(year);
    };
    if !(-9999..=9999).contains(&number) {
        return Some(year);
    }
    let mut date = format!("{number:0width$}", width = if number < 0 { 5 } else { 4 });
    if let Some(month) = field_text(entry, "month").and_then(|month| month_number(&month)) {
        let _ = write!(date, "-{month:02}");
        if let Some(day) = field_text(entry, "day").and_then(|day| day.parse::<u8>().ok())
            && (1..=31).contains(&day)
        {
            let _ = write!(date, "-{day:02}");
        }
    }
    Some(date)
}

fn month_number(month: &str) -> Option<u8> {
    if let Ok(number) = month.parse::<u8>() {
        return (1..=12).contains(&number).then_some(number);
    }
    MONTH_NAMES
        .iter()
        .position(|name| month.eq_ignore_ascii_case(name) || month.eq_ignore_ascii_case(&name[..3]))
        .map(|index| index as u8 + 1)
}
