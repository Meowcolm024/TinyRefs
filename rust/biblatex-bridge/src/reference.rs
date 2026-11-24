use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(crate) struct Reference {
    pub citation_key: String,
    pub entry_type: String,
    pub fields: BTreeMap<String, String>,
}
