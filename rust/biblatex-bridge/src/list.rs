use std::collections::BTreeMap;

use serde::Deserialize;

use crate::{export::validated_fields, reference::Reference};

#[derive(Deserialize)]
pub(crate) struct ListRequest {
    field: ListField,
    expression: String,
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
enum ListField {
    Author,
    Keywords,
}

impl ListRequest {
    pub fn items(self) -> Result<Vec<String>, String> {
        let name = match self.field {
            ListField::Author => "author",
            ListField::Keywords => "keywords",
        };
        let reference = Reference {
            citation_key: "list".into(),
            entry_type: "misc".into(),
            fields: BTreeMap::from([(name.into(), self.expression)]),
        };
        let fields = validated_fields(&reference)?;
        let inner = fields
            .get(name)
            .and_then(|value| value.strip_prefix('{'))
            .and_then(|value| value.strip_suffix('}'))
            .ok_or("Expected a BibLaTeX list expression.")?;
        split_items(inner.trim(), self.field)
    }
}

fn split_items(contents: &str, field: ListField) -> Result<Vec<String>, String> {
    let mut items = Vec::new();
    let mut depth = 0usize;
    let mut math = false;
    let mut start = 0;
    let mut chars = contents.char_indices();
    while let Some((index, character)) = chars.next() {
        if index < start {
            continue;
        }
        match character {
            '\\' => {
                chars.next();
            }
            '$' => math = !math,
            '{' => depth += 1,
            '}' if depth == 0 => return Err("Unbalanced groups in list expression.".into()),
            '}' => depth -= 1,
            _ if depth == 0 && !math => {
                let separator_length = match field {
                    ListField::Keywords if character == ',' => 1,
                    ListField::Author
                        if contents[index..].starts_with("and")
                            && contents[..index]
                                .chars()
                                .next_back()
                                .is_some_and(char::is_whitespace)
                            && contents[index + 3..]
                                .chars()
                                .next()
                                .is_some_and(char::is_whitespace) =>
                    {
                        3
                    }
                    _ => continue,
                };
                let item = contents[start..index].trim();
                if !item.is_empty() {
                    items.push(item.to_owned());
                }
                start = index + separator_length;
            }
            _ => {}
        }
    }
    if depth != 0 {
        return Err("Unbalanced groups in list expression.".into());
    }
    let tail = contents[start..].trim();
    if !tail.is_empty() {
        items.push(tail.to_owned());
    }
    Ok(items)
}
