use std::collections::{BTreeMap, HashMap, HashSet};

use biblatex::{Field, RawBibliography, RawChunk};
use serde::Serialize;

#[derive(Debug, Serialize)]
pub(crate) struct Reference<'a> {
    citation_key: &'a str,
    entry_type: String,
    fields: BTreeMap<String, String>,
}

pub(crate) fn parse(source: &str) -> Result<Vec<Reference<'_>>, String> {
    let bibliography = RawBibliography::parse(source)
        .map_err(|error| format!("{} at byte {}.", error.kind, error.span.start))?;
    let macros: HashMap<_, _> = bibliography
        .abbreviations
        .into_iter()
        .map(|pair| (pair.key.v.to_ascii_lowercase(), pair.value.v))
        .collect();

    let mut keys = HashSet::new();
    let mut references = Vec::with_capacity(bibliography.entries.len());
    for entry in bibliography.entries {
        let key = entry.v.key.v;
        if key.is_empty() {
            return Err(format!(
                "Missing citation key at byte {}.",
                entry.v.key.span.start
            ));
        }
        if !keys.insert(key) {
            return Err(format!("Duplicate citation key {key:?}."));
        }

        let mut fields = BTreeMap::new();
        for field in entry.v.fields {
            let name = field.key.v.to_ascii_lowercase();
            let value = expand_field(&field.value.v, &macros)
                .map_err(|error| format!("Entry {key:?}, field {name:?}: {error}"))?;
            if fields.insert(name.clone(), value).is_some() {
                return Err(format!("Duplicate field {name:?} in entry {key:?}."));
            }
        }

        references.push(Reference {
            citation_key: key,
            entry_type: entry.v.kind.v.to_ascii_lowercase(),
            fields,
        });
    }
    Ok(references)
}

fn expand_field(field: &Field<'_>, macros: &HashMap<String, Field<'_>>) -> Result<String, String> {
    let mut expression = String::from("{");
    let mut frames = vec![(None, field.iter())];
    let mut active_macros = HashSet::new();

    // Keep expansion frames on the heap so long chains of macros fit.
    while let Some((name, chunks)) = frames.last_mut() {
        let Some(chunk) = chunks.next() else {
            if let Some(name) = name {
                active_macros.remove(name);
            }
            frames.pop();
            continue;
        };

        match chunk.v {
            RawChunk::Normal(value) => {
                if !has_balanced_groups(value) {
                    return Err(format!("Unbalanced braces at byte {}.", chunk.span.start));
                }
                expression.push_str(value);
            }
            RawChunk::Abbreviation(name) => {
                let normalized = name.to_ascii_lowercase();
                if let Some((name, value)) = macros.get_key_value(&normalized) {
                    if !active_macros.insert(name) {
                        return Err(format!("Circular string macro {name:?}."));
                    }
                    frames.push((Some(name), value.iter()));
                } else if let Some(month) = month_macro(&normalized) {
                    expression.push_str(month);
                } else {
                    return Err(format!("Undefined string macro {name:?}."));
                }
            }
        }
    }
    expression.push('}');
    Ok(expression)
}

// Quoted literals can reach the raw parser with unbalanced groups.
fn has_balanced_groups(value: &str) -> bool {
    let mut chars = value.chars();
    let mut depth = 0usize;
    while let Some(character) = chars.next() {
        match character {
            '\\' => {
                chars.next();
            }
            '{' => depth += 1,
            '}' if depth == 0 => return false,
            '}' => depth -= 1,
            _ => {}
        }
    }
    depth == 0
}

fn month_macro(name: &str) -> Option<&'static str> {
    match name {
        "jan" => Some("January"),
        "feb" => Some("February"),
        "mar" => Some("March"),
        "apr" => Some("April"),
        "may" => Some("May"),
        "jun" => Some("June"),
        "jul" => Some("July"),
        "aug" => Some("August"),
        "sep" => Some("September"),
        "oct" => Some("October"),
        "nov" => Some("November"),
        "dec" => Some("December"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::parse;

    #[test]
    fn preserves_explicit_fields_and_expands_macros() {
        let references = parse(
            r#"
            @string{prefix = "Étude "}
            @string{label = PREFIX # "{NASA}"}
            @NovelKind{Key,
                Title = label # " mission",
                Extra = {\LaTeX},
                note = "",
                year = 2026,
                month = JAN,
                crossref = {Parent},
                xdata = {Shared}
            }
            @xdata{Shared, title = {Shared title}}
            @book{key,}
            "#,
        )
        .unwrap();
        assert_eq!(references.len(), 3);
        let reference = &references[0];
        assert_eq!(reference.citation_key, "Key");
        assert_eq!(reference.entry_type, "novelkind");
        assert_eq!(reference.fields["title"], "{Étude {NASA} mission}");
        assert_eq!(reference.fields["extra"], r"{\LaTeX}");
        assert_eq!(reference.fields["note"], "{}");
        assert_eq!(reference.fields["year"], "{2026}");
        assert_eq!(reference.fields["month"], "{January}");
        assert_eq!(reference.fields["crossref"], "{Parent}");
        assert_eq!(reference.fields["xdata"], "{Shared}");
        assert_eq!(references[1].entry_type, "xdata");
        assert_eq!(references[2].citation_key, "key");
    }

    #[test]
    fn rejects_invalid_entries() {
        assert!(parse("@book{k, title = {unfinished}").is_err());
        assert!(
            parse("@book{k,} @book{k,}")
                .unwrap_err()
                .contains("Duplicate citation key")
        );
        assert!(
            parse("@book{k,Title={a}, title={b}}")
                .unwrap_err()
                .contains("Duplicate field")
        );
        assert!(
            parse("@book{,}")
                .unwrap_err()
                .contains("Missing citation key")
        );
        assert!(
            parse("@book{k, title = \"unclosed {group\"}")
                .unwrap_err()
                .contains("Unbalanced braces")
        );
    }

    #[test]
    fn rejects_undefined_and_circular_macros() {
        let err = parse("@book{k,title=missing}").unwrap_err();
        assert!(err.contains("Undefined string macro"));
        let err = parse("@string{a=b} @string{b=a} @book{k,title=a}").unwrap_err();
        assert!(err.contains("Circular string macro"));
    }
}
