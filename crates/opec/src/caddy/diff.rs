//! Pure-function diff between two Caddy route arrays.
//!
//! Routes are matched by their `@id` field (e.g. `"tenant:cheburator"`).
//! Comparison is shallow `==` on the `serde_json::Value` — exact byte
//! equality after deserialization, not semantic equivalence.

#![allow(dead_code)] // pub API stub; used by binary in sub-phase 4.2
use serde_json::Value;

/// Diff result between live Caddy route state and proposed state.
#[derive(Debug, Default)]
pub struct RouteDiff {
    /// Routes present in `proposed` but not in `live`.
    pub added: Vec<Value>,
    /// `@id` values of routes present in `live` but not in `proposed`.
    pub removed: Vec<String>,
    /// Routes where `@id` exists in both but content differs.
    /// Tuple: (`@id`, before, after).
    pub changed: Vec<(String, Value, Value)>,
    /// Count of routes identical in both arrays.
    pub unchanged: usize,
}

/// Compare two Caddy route arrays by `@id`.
///
/// - `live`: current routes from `GET /config/apps/http/servers/srv0/routes`
/// - `proposed`: routes produced by the renderer for the current tenant yaml
pub fn diff_routes(live: &[Value], proposed: &[Value]) -> RouteDiff {
    let mut diff = RouteDiff::default();

    // Build id → value maps.
    let live_map = id_map(live);
    let proposed_map = id_map(proposed);

    // Added: in proposed, not in live.
    for (id, val) in &proposed_map {
        if !live_map.contains_key(id) {
            diff.added.push((*val).clone());
        }
    }

    // Removed: in live, not in proposed.
    for id in live_map.keys() {
        if !proposed_map.contains_key(id) {
            diff.removed.push(id.clone());
        }
    }

    // Changed / unchanged: in both.
    for (id, prop_val) in &proposed_map {
        if let Some(live_val) = live_map.get(id) {
            if live_val == prop_val {
                diff.unchanged += 1;
            } else {
                diff.changed
                    .push((id.clone(), (*live_val).clone(), (*prop_val).clone()));
            }
        }
    }

    // Stable sort for deterministic output.
    diff.added.sort_by_key(|v| route_id(v).unwrap_or_default());
    diff.removed.sort();
    diff.changed.sort_by_key(|(id, _, _)| id.clone());

    diff
}

/// Extract `@id` string from a route object.
fn route_id(v: &Value) -> Option<String> {
    v.get("@id")?.as_str().map(String::from)
}

/// Build a `HashMap<String, &Value>` keyed on the `@id` field.
/// Routes without `@id` are silently skipped.
fn id_map(routes: &[Value]) -> std::collections::HashMap<String, &Value> {
    routes
        .iter()
        .filter_map(|v| route_id(v).map(|id| (id, v)))
        .collect()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn route(id: &str, extra: serde_json::Value) -> Value {
        let mut v = json!({
            "@id": id,
            "match": [{"host": [format!("{id}.example.com")]}],
            "handle": [{"handler": "subroute", "routes": []}],
            "terminal": true
        });
        if let (Some(obj), Some(ext)) = (v.as_object_mut(), extra.as_object()) {
            for (k, val) in ext {
                obj.insert(k.clone(), val.clone());
            }
        }
        v
    }

    #[test]
    fn diff_detects_added_route() {
        let live = vec![route("tenant:alpha", json!({}))];
        let proposed = vec![
            route("tenant:alpha", json!({})),
            route("tenant:beta", json!({})),
        ];
        let d = diff_routes(&live, &proposed);
        assert_eq!(d.added.len(), 1);
        assert_eq!(d.added[0]["@id"], "tenant:beta");
        assert!(d.removed.is_empty());
        assert_eq!(d.unchanged, 1);
    }

    #[test]
    fn diff_detects_removed_route() {
        let live = vec![
            route("tenant:alpha", json!({})),
            route("tenant:gamma", json!({})),
        ];
        let proposed = vec![route("tenant:alpha", json!({}))];
        let d = diff_routes(&live, &proposed);
        assert!(d.added.is_empty());
        assert_eq!(d.removed, vec!["tenant:gamma"]);
        assert_eq!(d.unchanged, 1);
    }

    #[test]
    fn diff_detects_changed_route() {
        let live = vec![route("tenant:alpha", json!({"terminal": false}))];
        // proposed has terminal: true (default in route() helper)
        let proposed = vec![route("tenant:alpha", json!({}))];
        let d = diff_routes(&live, &proposed);
        // live has terminal:false, proposed has terminal:true → changed
        // (Both start with terminal:true from the helper, then live gets terminal:false
        //  merged — actually let's construct more explicitly)
        // Actually the helper sets terminal:true, then merges extra. So live gets terminal:false.
        assert_eq!(d.changed.len(), 1);
        assert_eq!(d.changed[0].0, "tenant:alpha");
    }

    #[test]
    fn diff_counts_unchanged() {
        let a = route("tenant:alpha", json!({}));
        let b = route("tenant:beta", json!({}));
        let live = vec![a.clone(), b.clone()];
        let proposed = vec![a, b];
        let d = diff_routes(&live, &proposed);
        assert_eq!(d.unchanged, 2);
        assert!(d.added.is_empty());
        assert!(d.removed.is_empty());
        assert!(d.changed.is_empty());
    }

    #[test]
    fn diff_routes_without_id_are_ignored() {
        let no_id = json!({"match": [{"host": ["x.example.com"]}], "handle": [{"handler": "static_response"}]});
        let live = vec![no_id.clone()];
        let proposed = vec![no_id];
        let d = diff_routes(&live, &proposed);
        // Both ignored; all counts zero.
        assert_eq!(d.added.len(), 0);
        assert_eq!(d.removed.len(), 0);
        assert_eq!(d.unchanged, 0);
    }
}
