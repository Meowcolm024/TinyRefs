use std::collections::{BTreeMap, HashMap, HashSet};

use crate::{
    import::{expand_field, parse_raw},
    reference::Reference,
};

pub(crate) fn serialize(references: &[Reference]) -> Result<String, String> {
    let mut output = String::new();
    let mut keys = HashSet::new();
    for reference in references {
        let key = &reference.citation_key;
        if !keys.insert(key) {
            return Err(format!("Duplicate citation key {key:?}."));
        }
        let fields =
            validated_fields(reference).map_err(|error| format!("Entry {key:?}: {error}"))?;
        if !output.is_empty() {
            output.push('\n');
        }
        write_entry(
            &mut output,
            &reference.entry_type.to_ascii_lowercase(),
            key,
            &fields,
        );
    }
    Ok(output)
}

pub(crate) fn validated_fields(reference: &Reference) -> Result<BTreeMap<String, String>, String> {
    if reference.citation_key.is_empty() {
        return Err("Missing citation key.".into());
    }
    if matches!(
        reference.entry_type.to_ascii_lowercase().as_str(),
        "comment" | "preamble" | "string"
    ) {
        return Err(format!("Reserved entry type {:?}.", reference.entry_type));
    }

    let mut candidate = String::new();
    write_entry(
        &mut candidate,
        &reference.entry_type,
        &reference.citation_key,
        &reference.fields,
    );
    let parsed = parse_raw(&candidate)?;
    let [entry] = parsed.entries.as_slice() else {
        return Err("Expected exactly one bibliography entry.".into());
    };
    if entry.v.kind.v != reference.entry_type {
        return Err(format!("Invalid entry type {:?}.", reference.entry_type));
    }
    if entry.v.key.v != reference.citation_key {
        return Err(format!(
            "Invalid citation key {:?}.",
            reference.citation_key
        ));
    }
    if entry.span.start != 0
        || entry.span.end != candidate.len() - "}\n".len()
        || entry.v.fields.len() != reference.fields.len()
    {
        return Err("Expected exactly the supplied bibliography fields.".into());
    }

    // The raw parser accepts file-level comments and trailing punctuation.
    // Check each span against its full input before accepting it as a field expression.
    let mut fields = BTreeMap::new();
    let macros = HashMap::new();
    for (field, (name, expression)) in entry.v.fields.iter().zip(&reference.fields) {
        if field.key.v != name {
            return Err(format!("Invalid field name {name:?}."));
        }
        if candidate[field.value.span.clone()].trim() != expression.trim() {
            return Err(format!("Expected one expression for field {name:?}."));
        }
        let value = expand_field(&field.value.v, &macros)
            .map_err(|error| format!("Field {name:?}: {error}"))?;
        if fields.insert(name.to_ascii_lowercase(), value).is_some() {
            return Err(format!("Duplicate field {name:?}."));
        }
    }
    Ok(fields)
}

fn write_entry(
    output: &mut String,
    entry_type: &str,
    key: &str,
    fields: &BTreeMap<String, String>,
) {
    output.push('@');
    output.push_str(entry_type);
    output.push('{');
    output.push_str(key);
    output.push_str(",\n");
    for (name, expression) in fields {
        output.push_str("  ");
        output.push_str(name);
        output.push_str(" = ");
        output.push_str(expression);
        output.push_str(",\n");
    }
    output.push_str("}\n");
}

#[cfg(test)]
mod tests {
    use super::serialize;
    use crate::{import::parse, reference::Reference};
    use std::collections::BTreeMap;

    #[test]
    fn round_trip_preserves_unknown_metadata_and_links() {
        let source = r#"
            @string{logic = "{System T}"}
            @TypeSystem{GödelT,
                Title = logic # " and primitive recursion",
                author = {Gödel, Kurt},
                custom = {$\lambda$-calculus},
                note = {},
                crossref = {ProofTheory},
                xdata = {LogicNotes}
            }
            @xdata{LogicNotes, subject = {Computability}}
            "#;
        let references = parse(source).unwrap();
        let rendered = serialize(&references).unwrap();
        assert!(rendered.starts_with("@typesystem{GödelT,\n"));
        assert!(rendered.contains("title = {{System T} and primitive recursion},"));
        assert_eq!(parse(&rendered).unwrap(), references);
    }

    #[test]
    fn canonicalizes_directly_entered_values() {
        let reference = Reference {
            citation_key: "SystemT".into(),
            entry_type: "TypeSystem".into(),
            fields: BTreeMap::from([
                ("Year".into(), "1958".into()),
                ("title".into(), r#""Gödel's " # "{System T}""#.into()),
                ("month".into(), "jan".into()),
            ]),
        };
        let rendered = serialize(&[reference]).unwrap();
        assert_eq!(
            rendered,
            "@typesystem{SystemT,\n  month = {January},\n  title = {Gödel's {System T}},\n  year = {1958},\n}\n"
        );
        assert_eq!(serialize(&[]).unwrap(), "");
    }

    #[test]
    fn rejects_invalid_identifiers_and_field_expressions() {
        for (key, kind, field, expression) in [
            ("", "article", "title", "{System T}"),
            ("System T", "article", "title", "{System T}"),
            ("SystemT", "string", "title", "{System T}"),
            ("SystemT", "type system", "title", "{System T}"),
            ("SystemT", "article", "full title", "{System T}"),
            ("SystemT", "article", "title ", "{System T}"),
            ("SystemT", "article", "title", "{System T"),
            ("SystemT", "article", "title", "unknownMacro"),
            ("SystemT", "article", "title", "{System T} % discarded"),
            ("SystemT", "article", "title", "{System T},"),
            ("SystemT", "article", "title", "{System T}, note = {extra}"),
            ("SystemT", "article", "title", "{System T},}\n@book{extra,"),
        ] {
            let reference = Reference {
                citation_key: key.into(),
                entry_type: kind.into(),
                fields: BTreeMap::from([(field.into(), expression.into())]),
            };
            assert!(
                serialize(&[reference]).is_err(),
                "accepted {key:?} {kind:?} {field:?} {expression:?}"
            );
        }
    }
}
