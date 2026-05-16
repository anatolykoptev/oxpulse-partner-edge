//! Tenant YAML schema — structs that map 1:1 to the tenants.yaml format.
//!
//! `schema_version: 1` is the only supported version in sub-phase 4.0.
//! Unknown action variants cause parse failure (serde internally-tagged enum).

use serde::{Deserialize, Serialize};

/// Root document — top-level of tenants.yaml.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct TenantsFile {
    pub schema_version: u32,
    pub tenants: Vec<Tenant>,
}

/// One tenant entry.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct Tenant {
    pub id: String,
    pub domains: Vec<String>,
    pub enabled: bool,
    #[serde(default)]
    pub routes: Vec<Route>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub security_headers: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub redirects: Vec<Redirect>,
}

/// A single route within a tenant. `action` is an internally-tagged enum
/// whose tag key is the YAML field `action:`. All action-specific fields
/// are flattened into the same YAML mapping.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct Route {
    pub path: String,
    #[serde(flatten)]
    pub action: RouteAction,
}

/// Discriminated union on `action: proxy | file_server`.
/// Unknown values cause a parse error (no `#[serde(other)]`).
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum RouteAction {
    Proxy {
        upstream: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        host_header: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sse: Option<bool>,
    },
    FileServer {
        root: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cache_control: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        try_files: Option<Vec<String>>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        strip_path_prefix: Option<String>,
    },
}

/// HTTP redirect rule attached to a tenant.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct Redirect {
    pub from_host: String,
    pub to: String,
    #[serde(default)]
    pub permanent: bool,
}

/// Parse raw YAML bytes into a [`TenantsFile`].
pub fn parse(src: &str) -> Result<TenantsFile, serde_yml::Error> {
    serde_yml::from_str(src)
}
