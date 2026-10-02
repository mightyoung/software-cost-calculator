use crate::error::{HubError, Result};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(deny_unknown_fields)]
pub struct RecordKey {
    pub entity_type: String,
    #[serde(deserialize_with = "canonical_uuid")]
    pub entity_id: Uuid,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct RecordSnapshot {
    pub entity_type: String,
    #[serde(deserialize_with = "canonical_uuid")]
    pub entity_id: Uuid,
    pub source_version: u64,
    pub data: Map<String, Value>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PublicationDraft {
    #[serde(deserialize_with = "canonical_uuid")]
    pub publication_id: Uuid,
    pub revision: u32,
    #[serde(default)]
    pub withdrawn: bool,
    pub root: RecordKey,
    pub records: Vec<RecordSnapshot>,
}
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Publication {
    pub origin: Uuid,
    #[serde(flatten)]
    pub draft: PublicationDraft,
}

// Flattened derive deserializers do not reliably reject surplus fields.
// Decode a strict flat wire representation before assembling the domain value.
impl<'de> Deserialize<'de> for Publication {
    fn deserialize<D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> std::result::Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Wire {
            #[serde(deserialize_with = "canonical_uuid")]
            origin: Uuid,
            #[serde(deserialize_with = "canonical_uuid")]
            publication_id: Uuid,
            revision: u32,
            #[serde(default)]
            withdrawn: bool,
            root: RecordKey,
            records: Vec<RecordSnapshot>,
        }
        let wire = Wire::deserialize(deserializer)?;
        Ok(Self {
            origin: wire.origin,
            draft: PublicationDraft {
                publication_id: wire.publication_id,
                revision: wire.revision,
                withdrawn: wire.withdrawn,
                root: wire.root,
                records: wire.records,
            },
        })
    }
}

fn invalid(message: impl Into<String>) -> HubError {
    HubError::Invalid(message.into())
}
fn canonical_uuid<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<Uuid, D::Error> {
    let text = String::deserialize(deserializer)?;
    let id = Uuid::parse_str(&text).map_err(serde::de::Error::custom)?;
    if id.to_string() != text || check_id(id).is_err() {
        return Err(serde::de::Error::custom(
            "lowercase canonical UUID v4 required",
        ));
    }
    Ok(id)
}
fn check_id(id: Uuid) -> Result<()> {
    if id.get_version_num() != 4 || id.get_variant() != uuid::Variant::RFC4122 {
        return Err(invalid("UUID v4 required"));
    }
    Ok(())
}
fn fields(kind: &str) -> Result<&'static str> {
    Ok(match kind {
        "supplier" => "name aliases address categories notes merged_into rating rating_note",
        "contact" => "supplier_id name phone wechat email notes",
        "product" => {
            "name unit brand model specification category notes merged_into attributes unit_conversions spec_class source_attachment_ids"
        }
        "project" => {
            "code name status type level customer contract_no contract_amount department leader start_date end_date currency tax_mode markup_rate notes"
        }
        "quotation" => {
            "supplier_id product_id price currency tax_mode unit_snapshot min_qty quoted_on contact_id contact_snapshot tax_rate lead_time_days valid_until notes project_id inquiry_location inquirer_name inquiry_precision inquiry_date inquired_at inquiry_utc_offset_minutes capture_mode includes warranty_months extra_cost deal_price awarded_on award_note inquiry_id attachment_ids price_basis price_tiers"
        }
        "project_item" => {
            "project_id category product_id name qty unit quotation_id unit_cost unit_price requirement notes"
        }
        "inquiry" => "project_id title item_ids supplier_ids due_date status notes",
        _ => return Err(invalid(format!("unsupported v1 entity: {kind}"))),
    })
}
fn refs(kind: &str) -> &'static [(&'static str, &'static str)] {
    match kind {
        "supplier" => &[("merged_into", "supplier")],
        "product" => &[("merged_into", "product")],
        "contact" => &[("supplier_id", "supplier")],
        "quotation" => &[
            ("supplier_id", "supplier"),
            ("product_id", "product"),
            ("contact_id", "contact"),
            ("project_id", "project"),
            ("inquiry_id", "inquiry"),
        ],
        "project_item" => &[
            ("project_id", "project"),
            ("product_id", "product"),
            ("quotation_id", "quotation"),
        ],
        "inquiry" => &[("project_id", "project")],
        _ => &[],
    }
}
fn decimal(value: &Value, positive: bool) -> Result<u128> {
    let s = value
        .as_str()
        .ok_or_else(|| invalid("decimal string required"))?;
    let parts: Vec<_> = s.split('.').collect();
    if parts.len() > 2
        || parts[0].is_empty()
        || parts[0].len() > 12
        || parts
            .iter()
            .any(|p| p.is_empty() || !p.bytes().all(|b| b.is_ascii_digit()))
        || parts.get(1).is_some_and(|p| p.len() > 6)
    {
        return Err(invalid(
            "decimal must have at most 12 integer and 6 fractional digits",
        ));
    }
    let whole = parts[0]
        .parse::<u128>()
        .map_err(|_| invalid("invalid decimal"))?;
    let fraction = parts.get(1).copied().unwrap_or("");
    let micros = whole * 1_000_000
        + if fraction.is_empty() {
            0
        } else {
            fraction
                .parse::<u128>()
                .map_err(|_| invalid("invalid decimal"))?
                * 10_u128.pow(6 - fraction.len() as u32)
        };
    if positive && micros == 0 {
        return Err(invalid("positive decimal required"));
    }
    Ok(micros)
}
fn text(data: &Map<String, Value>, field: &str, required: bool) -> Result<()> {
    match data.get(field).filter(|v| !v.is_null()) {
        None if required => Err(invalid(format!("{field} required"))),
        None => Ok(()),
        Some(Value::String(s)) if !s.trim().is_empty() && s.chars().count() <= 2000 => Ok(()),
        _ => Err(invalid(format!("invalid {field}"))),
    }
}
fn date(value: &Value) -> Result<()> {
    let s = value
        .as_str()
        .ok_or_else(|| invalid("date text required"))?;
    let bytes = s.as_bytes();
    if bytes.len() != 10
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || !bytes
            .iter()
            .enumerate()
            .all(|(i, b)| i == 4 || i == 7 || b.is_ascii_digit())
    {
        return Err(invalid("date must be YYYY-MM-DD"));
    }
    let year = s[..4].parse::<u32>().map_err(|_| invalid("invalid date"))?;
    let month = s[5..7]
        .parse::<u32>()
        .map_err(|_| invalid("invalid date"))?;
    let day = s[8..].parse::<u32>().map_err(|_| invalid("invalid date"))?;
    let max = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) => 29,
        2 => 28,
        _ => 0,
    };
    if year == 0 || day == 0 || day > max {
        return Err(invalid("invalid calendar date"));
    }
    Ok(())
}
fn enum_field(data: &Map<String, Value>, field: &str, values: &[&str]) -> Result<()> {
    if let Some(v) = data.get(field).filter(|v| !v.is_null())
        && !values.contains(&v.as_str().unwrap_or(""))
    {
        return Err(invalid(format!("invalid {field}")));
    }
    Ok(())
}
fn bounded(value: &Value, depth: u8) -> Result<()> {
    if depth > 5 {
        return Err(invalid("payload nesting too deep"));
    }
    match value {
        Value::String(s) if s.chars().count() > 2000 => return Err(invalid("string too long")),
        Value::Array(a) => {
            if a.len() > 256 {
                return Err(invalid("array too long"));
            }
            for v in a {
                bounded(v, depth + 1)?;
            }
        }
        Value::Object(m) => {
            if m.len() > 64 {
                return Err(invalid("object too large"));
            }
            for (k, v) in m {
                if k.len() > 100 {
                    return Err(invalid("key too long"));
                }
                bounded(v, depth + 1)?;
            }
        }
        Value::Number(n) if !n.is_i64() && !n.is_u64() => {
            return Err(invalid("floating point data unsupported"));
        }
        _ => {}
    }
    Ok(())
}
impl RecordSnapshot {
    pub fn key(&self) -> RecordKey {
        RecordKey {
            entity_type: self.entity_type.clone(),
            entity_id: self.entity_id,
        }
    }
    fn dependencies(&self) -> Result<Vec<RecordKey>> {
        let mut result = Vec::new();
        let mut add = |target: &str, value: &Value| -> Result<()> {
            let s = value
                .as_str()
                .ok_or_else(|| invalid("reference must be UUID text"))?;
            let id = Uuid::parse_str(s).map_err(|_| invalid("invalid reference UUID"))?;
            check_id(id)?;
            if id.to_string() != s {
                return Err(invalid("reference UUID must be lowercase canonical"));
            }
            result.push(RecordKey {
                entity_type: target.into(),
                entity_id: id,
            });
            Ok(())
        };
        for (field, target) in refs(&self.entity_type) {
            if let Some(v) = self.data.get(*field).filter(|v| !v.is_null()) {
                add(target, v)?;
            }
        }
        if self.entity_type == "inquiry" {
            for (field, target) in [("item_ids", "project_item"), ("supplier_ids", "supplier")] {
                if let Some(v) = self.data.get(field).filter(|v| !v.is_null()) {
                    for id in v
                        .as_array()
                        .ok_or_else(|| invalid("reference list required"))?
                    {
                        add(target, id)?;
                    }
                }
            }
        }
        Ok(result)
    }
    fn validate(&self) -> Result<()> {
        check_id(self.entity_id)?;
        if self.source_version == 0 || self.source_version > i64::MAX as u64 {
            return Err(invalid("invalid source version"));
        }
        let allowed = fields(&self.entity_type)?;
        for (key, value) in &self.data {
            if !allowed.split(' ').any(|f| f == key) {
                return Err(invalid(format!("unknown {} field {key}", self.entity_type)));
            }
            // Known structured fields are checked individually below. Everything
            // else in the Dart payload is scalar; retain its exact raw value.
            if !value.is_null() {
                match key.as_str() {
                    "aliases"
                    | "categories"
                    | "includes"
                    | "attachment_ids"
                    | "price_tiers"
                    | "source_attachment_ids"
                    | "item_ids"
                    | "supplier_ids"
                        if !value.is_array() =>
                    {
                        return Err(invalid(format!("{key} must be an array")));
                    }
                    "attributes" | "unit_conversions" | "contact_snapshot"
                        if !value.is_object() =>
                    {
                        return Err(invalid(format!("{key} must be an object")));
                    }
                    "lead_time_days" | "warranty_months" | "inquiry_utc_offset_minutes"
                        if !value.is_i64() =>
                    {
                        return Err(invalid(format!("{key} must be an integer")));
                    }
                    "aliases"
                    | "categories"
                    | "includes"
                    | "attachment_ids"
                    | "source_attachment_ids"
                    | "price_tiers"
                    | "item_ids"
                    | "supplier_ids"
                    | "attributes"
                    | "unit_conversions"
                    | "contact_snapshot"
                    | "lead_time_days"
                    | "warranty_months"
                    | "inquiry_utc_offset_minutes" => {}
                    _ if !value.is_string() => return Err(invalid(format!("{key} must be text"))),
                    _ => {}
                }
            }
            bounded(value, 0)?;
        }
        for field in [
            "notes",
            "rating_note",
            "address",
            "name",
            "title",
            "unit",
            "unit_snapshot",
            "brand",
            "model",
            "specification",
            "category",
            "code",
            "customer",
            "contract_no",
            "department",
            "leader",
            "inquiry_location",
            "inquirer_name",
            "award_note",
            "phone",
            "email",
            "wechat",
        ] {
            text(&self.data, field, false)?;
        }
        for field in [
            "quoted_on",
            "valid_until",
            "awarded_on",
            "inquiry_date",
            "start_date",
            "end_date",
            "due_date",
        ] {
            if let Some(v) = self.data.get(field).filter(|v| !v.is_null()) {
                date(v)?;
            }
        }
        for (field, max) in [("lead_time_days", 36500), ("warranty_months", 600)] {
            if let Some(v) = self.data.get(field).filter(|v| !v.is_null())
                && v.as_u64().is_none_or(|n| n > max)
            {
                return Err(invalid(format!("invalid {field}")));
            }
        }
        for field in ["aliases", "categories"] {
            if let Some(v) = self.data.get(field).filter(|v| !v.is_null()) {
                let a = v.as_array().ok_or_else(|| invalid("text list required"))?;
                if a.len() > 20
                    || a.iter().any(|v| {
                        v.as_str()
                            .is_none_or(|s| s.trim().is_empty() || s.chars().count() > 200)
                    })
                {
                    return Err(invalid("invalid text list"));
                }
            }
        }
        if let Some(v) = self
            .data
            .get("source_attachment_ids")
            .filter(|v| !v.is_null())
            && v.as_array().is_none_or(|a| !a.is_empty())
        {
            return Err(invalid(
                "v1 attachment transfer is unsupported; do not omit existing attachments",
            ));
        }
        for field in ["attributes", "unit_conversions"] {
            if let Some(v) = self.data.get(field).filter(|v| !v.is_null()) {
                let m = v.as_object().ok_or_else(|| invalid("object required"))?;
                if m.len() > 50 {
                    return Err(invalid("too many attributes or conversions"));
                }
                for (key, value) in m {
                    if key.trim().is_empty() || key.chars().count() > 50 {
                        return Err(invalid("invalid attribute or unit key"));
                    }
                    if field == "unit_conversions" {
                        decimal(value, true)?;
                        if self.data.get("unit").and_then(Value::as_str) == Some(key.as_str()) {
                            return Err(invalid("conversion cannot repeat base unit"));
                        }
                    } else if value
                        .as_str()
                        .is_none_or(|s| s.trim().is_empty() || s.chars().count() > 100)
                    {
                        return Err(invalid("invalid attribute"));
                    }
                }
            }
        }
        if let Some(v) = self.data.get("contact_snapshot").filter(|v| !v.is_null()) {
            let m = v
                .as_object()
                .ok_or_else(|| invalid("invalid contact snapshot"))?;
            if m.keys()
                .any(|k| !["name", "phone", "wechat", "email"].contains(&k.as_str()))
            {
                return Err(invalid("unknown contact snapshot field"));
            }
            text(m, "name", true)?;
            for f in ["phone", "wechat", "email"] {
                text(m, f, false)?;
            }
            if ["phone", "wechat", "email"]
                .iter()
                .all(|f| m.get(*f).is_none_or(Value::is_null))
            {
                return Err(invalid("contact snapshot requires contact method"));
            }
        }
        match self.entity_type.as_str() {
            "supplier" => {
                text(&self.data, "name", true)?;
                if let Some(v) = self.data.get("rating").filter(|v| !v.is_null())
                    && !["preferred", "caution", "disabled"].contains(&v.as_str().unwrap_or(""))
                {
                    return Err(invalid("invalid supplier rating"));
                }
            }
            "product" => {
                text(&self.data, "name", true)?;
                text(&self.data, "unit", true)?;
            }
            "contact" => {
                text(&self.data, "name", true)?;
                text(&self.data, "supplier_id", true)?;
                if ["phone", "wechat", "email"]
                    .iter()
                    .all(|f| self.data.get(*f).is_none_or(Value::is_null))
                {
                    return Err(invalid("contact requires contact method"));
                }
            }
            "quotation" => {
                for f in [
                    "supplier_id",
                    "product_id",
                    "unit_snapshot",
                    "currency",
                    "tax_mode",
                    "capture_mode",
                ] {
                    text(&self.data, f, true)?;
                }
                for f in ["price", "min_qty"] {
                    decimal(
                        self.data
                            .get(f)
                            .ok_or_else(|| invalid(format!("{f} required")))?,
                        f == "min_qty",
                    )?;
                }
                let currency = self.data["currency"].as_str().unwrap_or("");
                if currency.len() != 3 || !currency.bytes().all(|b| b.is_ascii_uppercase()) {
                    return Err(invalid("invalid currency"));
                }
                if !["included", "excluded", "unknown"]
                    .contains(&self.data["tax_mode"].as_str().unwrap_or(""))
                {
                    return Err(invalid("invalid tax mode"));
                }
                let mode = self.data["capture_mode"].as_str().unwrap_or("");
                if !["standard", "historical"].contains(&mode) {
                    return Err(invalid("invalid capture mode"));
                }
                if self.data.get("contact_id").is_some_and(|v| !v.is_null())
                    && self.data.get("contact_snapshot").is_none_or(Value::is_null)
                {
                    return Err(invalid("contact_id requires captured contact_snapshot"));
                }
                if mode == "standard" {
                    for f in ["project_id", "inquirer_name", "inquiry_date", "quoted_on"] {
                        text(&self.data, f, true)?;
                    }
                }
                if let Some(v) = self.data.get("attachment_ids").filter(|v| !v.is_null())
                    && v.as_array().is_none_or(|a| !a.is_empty())
                {
                    return Err(invalid(
                        "v1 attachment transfer is unsupported; do not omit existing attachments",
                    ));
                }
                if let Some(v) = self.data.get("tax_rate").filter(|v| !v.is_null())
                    && (decimal(v, false)? > 100_000_000
                        || v.as_str().is_some_and(|s| {
                            s.split('.').next().is_some_and(|p| p.len() > 3)
                                || s.split_once('.')
                                    .is_some_and(|(_, fraction)| fraction.len() > 4)
                        }))
                {
                    return Err(invalid(
                        "tax_rate requires at most 3 integer and 4 fraction digits, at most 100",
                    ));
                }
                enum_field(&self.data, "price_basis", &["verbal", "reference"])?;
                if let Some(v) = self.data.get("includes").filter(|v| !v.is_null()) {
                    for item in v
                        .as_array()
                        .ok_or_else(|| invalid("includes must be array"))?
                    {
                        if !["freight", "installation", "commissioning", "training"]
                            .contains(&item.as_str().unwrap_or(""))
                        {
                            return Err(invalid("unknown quote inclusion"));
                        }
                    }
                }
                if let Some(until) = self.data.get("valid_until").filter(|v| !v.is_null()) {
                    let quoted = self
                        .data
                        .get("quoted_on")
                        .and_then(Value::as_str)
                        .ok_or_else(|| invalid("valid_until requires quoted_on"))?;
                    if until.as_str().unwrap_or("") < quoted {
                        return Err(invalid("valid_until before quoted_on"));
                    }
                }
                if self.data.get("awarded_on").is_some_and(|v| !v.is_null())
                    && self.data.get("deal_price").is_none_or(Value::is_null)
                {
                    return Err(invalid("award requires deal_price"));
                }
                if let Some(v) = self.data.get("price_tiers").filter(|v| !v.is_null()) {
                    let tiers = v.as_array().ok_or_else(|| invalid("invalid price tiers"))?;
                    if tiers.is_empty() || tiers.len() > 10 {
                        return Err(invalid("invalid price tiers"));
                    }
                    let mut floor = decimal(&self.data["min_qty"], true)?;
                    for tier in tiers {
                        let t = tier.as_object().ok_or_else(|| invalid("invalid tier"))?;
                        if t.len() != 2 {
                            return Err(invalid("tier requires price and min_qty"));
                        }
                        let qty = decimal(
                            t.get("min_qty")
                                .ok_or_else(|| invalid("tier quantity required"))?,
                            true,
                        )?;
                        decimal(
                            t.get("price")
                                .ok_or_else(|| invalid("tier price required"))?,
                            false,
                        )?;
                        if qty <= floor {
                            return Err(invalid("tier quantities must increase"));
                        }
                        floor = qty;
                    }
                }
            }
            "project" => {
                text(&self.data, "name", true)?;
            }
            "project_item" | "inquiry" => {
                text(&self.data, "project_id", true)?;
            }
            _ => {}
        }
        for f in [
            "extra_cost",
            "deal_price",
            "contract_amount",
            "markup_rate",
            "qty",
            "unit_cost",
            "unit_price",
        ] {
            if let Some(v) = self.data.get(f).filter(|v| !v.is_null()) {
                decimal(v, f == "qty")?;
            }
        }
        self.dependencies()?;
        Ok(())
    }
}
impl PublicationDraft {
    pub fn normalize(&mut self) {
        self.records.sort_by_key(RecordSnapshot::key);
    }
    pub fn validate(&self) -> Result<()> {
        check_id(self.publication_id)?;
        check_id(self.root.entity_id)?;
        if self.revision == 0 || self.revision > i32::MAX as u32 {
            return Err(invalid("invalid publication revision"));
        }
        if !["supplier", "quotation"].contains(&self.root.entity_type.as_str()) {
            return Err(invalid("v1 root must be supplier or quotation"));
        }
        if self.records.is_empty()
            || self.records.len() > 256
            || serde_json::to_vec(self)?.len() > 1024 * 1024
        {
            return Err(invalid("publication bounds exceeded"));
        }
        let mut records = BTreeMap::new();
        for record in &self.records {
            record.validate()?;
            if records.insert(record.key(), record).is_some() {
                return Err(invalid("duplicate record"));
            }
        }
        if !records.contains_key(&self.root) {
            return Err(invalid("root missing"));
        }
        let mut queue = vec![self.root.clone()];
        if self.root.entity_type == "supplier" {
            for record in &self.records {
                if record.entity_type == "contact"
                    && record.data.get("supplier_id").and_then(Value::as_str)
                        == Some(self.root.entity_id.to_string().as_str())
                {
                    queue.push(record.key());
                }
            }
        }
        let mut seen = BTreeSet::new();
        while let Some(key) = queue.pop() {
            if !seen.insert(key.clone()) {
                continue;
            }
            let record = records.get(&key).ok_or_else(|| {
                invalid(format!(
                    "missing dependency {} {}",
                    key.entity_type, key.entity_id
                ))
            })?;
            queue.extend(record.dependencies()?);
        }
        if seen.len() != records.len() {
            return Err(invalid("unrelated records outside selected closure"));
        }
        for record in records.values() {
            if record.entity_type == "quotation" {
                for (field, kind, shared) in [
                    ("contact_id", "contact", "supplier_id"),
                    ("inquiry_id", "inquiry", "project_id"),
                ] {
                    if let Some(id) = record.data.get(field).and_then(Value::as_str) {
                        let id =
                            Uuid::parse_str(id).map_err(|_| invalid("invalid related UUID"))?;
                        let related = records
                            .get(&RecordKey {
                                entity_type: kind.into(),
                                entity_id: id,
                            })
                            .ok_or_else(|| invalid("missing relation"))?;
                        if record.data.get(shared) != related.data.get(shared) {
                            return Err(invalid(format!(
                                "quotation {shared} does not match {kind}"
                            )));
                        }
                    }
                }
            }
        }
        Ok(())
    }
    pub fn root_record(&self) -> Result<&RecordSnapshot> {
        self.records
            .iter()
            .find(|r| r.key() == self.root)
            .ok_or_else(|| invalid("root missing"))
    }
    pub fn title(&self) -> String {
        let Some(root) = self.records.iter().find(|r| r.key() == self.root) else {
            return String::new();
        };
        if root.entity_type == "supplier" {
            return root
                .data
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned();
        }
        let product_id = root
            .data
            .get("product_id")
            .and_then(Value::as_str)
            .and_then(|s| Uuid::parse_str(s).ok());
        self.records
            .iter()
            .find(|r| r.entity_type == "product" && Some(r.entity_id) == product_id)
            .and_then(|r| r.data.get("name"))
            .and_then(Value::as_str)
            .unwrap_or("Quotation")
            .to_owned()
    }
}
impl Publication {
    pub fn validate(&self) -> Result<()> {
        check_id(self.origin)?;
        self.draft.validate()?;
        // Export includes origin metadata as well as the submitted draft. Apply
        // the same payload bound before committing an accepted publication.
        if serde_json::to_vec(self)?.len() > 1024 * 1024 {
            return Err(invalid("publication including origin exceeds 1 MiB"));
        }
        Ok(())
    }
    pub fn digest(&self) -> Result<String> {
        let mut canonical = self.clone();
        canonical.draft.normalize();
        Ok(format!(
            "{:x}",
            Sha256::digest(serde_json::to_vec(&canonical)?)
        ))
    }
}
