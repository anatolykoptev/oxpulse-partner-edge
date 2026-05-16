//! Pure-function renderer: tenant YAML schema → Caddy admin-API JSON route objects.
//!
//! This is the single place that knows the Caddy JSON schema. The YAML schema
//! is stable; Caddy can evolve under it — bump and fix here only.
//!
//! Entry point: [`render_tenant_routes`]
//! Shape validator: [`validate_caddy_route_shape`]

use anyhow::{bail, Result};
use serde_json::{json, Value};

use crate::tenant::schema::{RouteAction, Tenant};

/// Render all tenants into a Vec of Caddy route objects, one per enabled tenant.
/// Disabled tenants are skipped.
/// Each redirect produces an additional route object appended after its tenant's main route.
pub fn render_tenant_routes(tenants: &[Tenant]) -> Vec<Value> {
    let mut out = Vec::new();
    for t in tenants {
        if !t.enabled {
            continue;
        }
        out.push(render_main_route(t));
        for r in &t.redirects {
            out.push(render_redirect_route(&t.id, r));
        }
    }
    out
}

/// Render the primary vhost route for one tenant.
fn render_main_route(t: &Tenant) -> Value {
    let subroutes: Vec<Value> = t.routes.iter().map(render_yaml_route).collect();

    json!({
        "@id": format!("tenant:{}", t.id),
        "match": [{ "host": t.domains }],
        "handle": [{
            "handler": "subroute",
            "routes": subroutes
        }],
        "terminal": true
    })
}

/// Render one yaml Route into one Caddy sub-route object.
fn render_yaml_route(route: &crate::tenant::schema::Route) -> Value {
    let match_block = json!([{ "path": [route.path.clone()] }]);

    let handlers = match &route.action {
        RouteAction::Proxy {
            upstream,
            host_header,
            sse,
        } => render_proxy_handlers(upstream, host_header.as_deref(), *sse),
        RouteAction::FileServer {
            root,
            cache_control,
            try_files,
            strip_path_prefix,
        } => render_file_server_handlers(
            root,
            cache_control.as_deref(),
            try_files.as_deref(),
            strip_path_prefix.as_deref(),
        ),
    };

    json!({
        "match": match_block,
        "handle": handlers
    })
}

/// Build handler chain for `action: proxy`.
fn render_proxy_handlers(
    upstream: &str,
    host_header: Option<&str>,
    sse: Option<bool>,
) -> Vec<Value> {
    // Parse upstream URL to determine scheme + dial address.
    let (scheme, dial) = parse_upstream(upstream);
    let use_tls = scheme == "https";
    let default_port = if use_tls { 443u16 } else { 80u16 };

    // Build dial string: host:port (parse from URL, add default if absent).
    let dial_addr = make_dial(upstream, default_port);

    let mut proxy = json!({
        "handler": "reverse_proxy",
        "upstreams": [{ "dial": dial_addr }]
    });

    if use_tls {
        proxy["transport"] = json!({ "protocol": "http", "tls": {} });
    }

    // Host header rewrite.
    let header_host = host_header.unwrap_or_else(|| {
        // Default: strip scheme, strip port if standard.
        host_from_url(upstream)
    });
    proxy["headers"] = json!({
        "request": {
            "set": { "Host": [header_host] }
        }
    });

    // SSE: disable buffering.
    if sse == Some(true) {
        proxy["flush_interval"] = json!(-1);
    }

    // Suppress unused variable warning
    let _ = dial;

    vec![proxy]
}

/// Extract scheme from an upstream URL string.
fn parse_upstream(url: &str) -> (&str, &str) {
    if let Some(rest) = url.strip_prefix("https://") {
        ("https", rest)
    } else if let Some(rest) = url.strip_prefix("http://") {
        ("http", rest)
    } else {
        ("http", url)
    }
}

/// Build Caddy dial address `host:port` from an upstream URL.
fn make_dial(url: &str, default_port: u16) -> String {
    let (_, rest) = parse_upstream(url);
    // rest = "host:port/path" or "host/path"
    let host_port = rest.split('/').next().unwrap_or(rest);
    if host_port.contains(':') {
        host_port.to_string()
    } else {
        format!("{host_port}:{default_port}")
    }
}

/// Extract `host` (no scheme, no port for standard ports) from URL.
fn host_from_url(url: &str) -> &str {
    let (_, rest) = parse_upstream(url);
    // strip path
    rest.split('/').next().unwrap_or(rest)
}

/// Build handler chain for `action: file_server`.
///
/// Chain (in order):
/// 1. Optional `rewrite` (strip_path_prefix)
/// 2. SPA fallback route (if `try_files` set): file matcher + rewrite handler.
///    Caddy 2 native JSON does NOT have a `try_files` field on `file_server`.
///    The equivalent is a nested subroute with a `file` matcher that rewrites
///    on miss — matching what `caddy adapt` produces from Caddyfile `try_files`.
/// 3. `file_server`
/// 4. Optional `headers` (Cache-Control)
fn render_file_server_handlers(
    root: &str,
    cache_control: Option<&str>,
    try_files: Option<&[String]>,
    strip_path_prefix: Option<&str>,
) -> Vec<Value> {
    let mut chain: Vec<Value> = Vec::new();

    // 1. Rewrite to strip path prefix if requested.
    if let Some(prefix) = strip_path_prefix {
        chain.push(json!({
            "handler": "rewrite",
            "strip_path_prefix": prefix
        }));
    }

    // 2. SPA fallback: file matcher + rewrite on miss.
    // In native Caddy JSON, try_files is expressed as:
    //   match: [{file: {try_files: [...]}}]
    //   handle: [{handler: rewrite, uri: "{http.matchers.file.relative}"}]
    if let Some(tf) = try_files {
        chain.push(json!({
            "handler": "subroute",
            "routes": [{
                "match": [{"file": {"try_files": tf, "root": root}}],
                "handle": [{"handler": "rewrite", "uri": "{http.matchers.file.relative}"}]
            }]
        }));
    }

    // 3. File server.
    let fs_handler = json!({
        "handler": "file_server",
        "root": root
    });
    chain.push(fs_handler);

    // 4. Cache-Control response header.
    if let Some(cc) = cache_control {
        chain.push(json!({
            "handler": "headers",
            "response": {
                "set": { "Cache-Control": [cc] }
            }
        }));
    }

    chain
}

/// Render a redirect rule as a standalone Caddy route object.
/// `permanent: true` → status 308; `permanent: false` → status 307.
fn render_redirect_route(tenant_id: &str, r: &crate::tenant::schema::Redirect) -> Value {
    let status = if r.permanent { 308 } else { 307 };
    json!({
        "@id": format!("tenant:{}:redirect:{}", tenant_id, r.from_host),
        "match": [{ "host": [r.from_host.clone()] }],
        "handle": [{
            "handler": "static_response",
            "headers": { "Location": [r.to.clone()] },
            "status_code": status
        }],
        "terminal": true
    })
}

// ---------------------------------------------------------------------------
// Shape validator — catch renderer bugs before PATCH
// ---------------------------------------------------------------------------

/// Validate that a rendered Caddy route object has the expected structural shape.
///
/// Checks:
/// - Has `match` or `handle` (at least one).
/// - Each handler object in `handle` has a `handler` string field.
/// - No unknown top-level keys (allowed: `@id`, `match`, `handle`, `terminal`, `group`).
///
/// Returns `Err` with a description of the first violation found.
pub fn validate_caddy_route_shape(v: &Value) -> Result<()> {
    let obj = match v.as_object() {
        Some(o) => o,
        None => bail!("route must be a JSON object"),
    };

    // No unknown top-level keys.
    const ALLOWED: &[&str] = &["@id", "match", "handle", "terminal", "group"];
    for key in obj.keys() {
        if !ALLOWED.contains(&key.as_str()) {
            bail!("unknown top-level key: {key:?}");
        }
    }

    // Must have match or handle.
    let has_match = obj.contains_key("match");
    let has_handle = obj.contains_key("handle");
    if !has_match && !has_handle {
        bail!("route must have at least one of `match` or `handle`");
    }

    // Each handler in handle must have a `handler` field.
    if let Some(handle) = obj.get("handle") {
        let arr = match handle.as_array() {
            Some(a) => a,
            None => bail!("`handle` must be an array"),
        };
        for (i, h) in arr.iter().enumerate() {
            match h.get("handler").and_then(|v| v.as_str()) {
                Some(_) => {}
                None => bail!("handle[{i}] missing `handler` string field"),
            }
        }
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tenant::schema::{parse, Redirect, Route, RouteAction, Tenant};

    fn proxy_tenant(sse: bool, host_header: Option<&str>) -> Tenant {
        Tenant {
            id: "test-proxy".to_string(),
            domains: vec!["proxy.example.com".to_string()],
            enabled: true,
            routes: vec![Route {
                path: "/api/*".to_string(),
                action: RouteAction::Proxy {
                    upstream: "https://backend.example.com".to_string(),
                    host_header: host_header.map(String::from),
                    sse: if sse { Some(true) } else { None },
                },
            }],
            security_headers: None,
            redirects: vec![],
        }
    }

    fn file_server_tenant(
        strip: Option<&str>,
        cache: Option<&str>,
        try_files: Option<Vec<String>>,
    ) -> Tenant {
        Tenant {
            id: "test-fs".to_string(),
            domains: vec!["fs.example.com".to_string()],
            enabled: true,
            routes: vec![Route {
                path: "/static/*".to_string(),
                action: RouteAction::FileServer {
                    root: "/srv/static".to_string(),
                    cache_control: cache.map(String::from),
                    try_files,
                    strip_path_prefix: strip.map(String::from),
                },
            }],
            security_headers: None,
            redirects: vec![],
        }
    }

    #[test]
    fn renders_proxy_route_with_tls() {
        let t = proxy_tenant(false, None);
        let routes = render_tenant_routes(&[t]);
        assert_eq!(routes.len(), 1);
        let route = &routes[0];
        // Drill into subroute → routes[0] → handle[0]
        let sub = &route["handle"][0]["routes"][0]["handle"][0];
        assert_eq!(sub["transport"]["protocol"], "http");
        assert!(
            sub["transport"]["tls"].is_object(),
            "tls block required for https upstream"
        );
    }

    #[test]
    fn renders_file_server_chain_with_strip_path() {
        let t = file_server_tenant(Some("/static"), None, None);
        let routes = render_tenant_routes(&[t]);
        let sub_routes = &routes[0]["handle"][0]["routes"][0]["handle"];
        let arr = sub_routes.as_array().unwrap();
        // Should have: rewrite + file_server
        assert!(
            arr.len() >= 2,
            "expected rewrite + file_server, got {}",
            arr.len()
        );
        assert_eq!(arr[0]["handler"], "rewrite");
        assert_eq!(arr[0]["strip_path_prefix"], "/static");
        assert_eq!(arr[1]["handler"], "file_server");
    }

    #[test]
    fn renders_sse_flush_interval() {
        let t = proxy_tenant(true, None);
        let routes = render_tenant_routes(&[t]);
        let proxy_handler = &routes[0]["handle"][0]["routes"][0]["handle"][0];
        assert_eq!(proxy_handler["flush_interval"], -1);
    }

    #[test]
    fn tags_each_route_with_at_id() {
        let t = proxy_tenant(false, None);
        let routes = render_tenant_routes(&[t]);
        let id = routes[0]["@id"].as_str().unwrap();
        assert_eq!(id, "tenant:test-proxy");
    }

    #[test]
    fn redirects_emit_separate_route() {
        let mut t = proxy_tenant(false, None);
        t.redirects.push(Redirect {
            from_host: "www.proxy.example.com".to_string(),
            to: "https://proxy.example.com{uri}".to_string(),
            permanent: true,
        });
        let routes = render_tenant_routes(&[t]);
        // 2 routes: main + redirect
        assert_eq!(routes.len(), 2);
        let redir = &routes[1];
        assert_eq!(redir["handle"][0]["handler"], "static_response");
        assert_eq!(redir["handle"][0]["status_code"], 308);
    }

    #[test]
    fn skips_disabled_tenant() {
        let mut t = proxy_tenant(false, None);
        t.enabled = false;
        let routes = render_tenant_routes(&[t]);
        assert!(routes.is_empty(), "disabled tenant must produce no routes");
    }

    #[test]
    fn validate_shape_passes_valid_route() {
        let t = proxy_tenant(false, None);
        let routes = render_tenant_routes(&[t]);
        for r in &routes {
            validate_caddy_route_shape(r).expect("shape must be valid");
        }
    }

    #[test]
    fn validate_shape_rejects_unknown_key() {
        let bad = serde_json::json!({
            "match": [{"host": ["x.example.com"]}],
            "handle": [{"handler": "static_response", "status_code": 200}],
            "bogus_field": true
        });
        assert!(validate_caddy_route_shape(&bad).is_err());
    }

    #[test]
    fn render_cheburator_fixture() {
        let src = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/valid_single_tenant.yaml"
        ));
        let file = parse(src).expect("parse fixture");
        let routes = render_tenant_routes(&file.tenants);
        // 1 main route + 1 redirect
        assert_eq!(routes.len(), 2);
        for r in &routes {
            validate_caddy_route_shape(r).expect("shape valid");
        }
    }

    #[test]
    fn file_server_cache_control_emits_headers_handler() {
        let t = file_server_tenant(None, Some("public, max-age=3600"), None);
        let routes = render_tenant_routes(&[t]);
        let handlers = routes[0]["handle"][0]["routes"][0]["handle"]
            .as_array()
            .unwrap();
        let last = handlers.last().unwrap();
        assert_eq!(last["handler"], "headers");
        assert_eq!(
            last["response"]["set"]["Cache-Control"][0],
            "public, max-age=3600"
        );
    }
}
