//! Pure-function validators for [`TenantsFile`].
//!
//! All validators collect ALL errors before returning — never first-fail.
//! Callers receive the full diagnostic list so the operator can fix everything
//! in one edit cycle.

use regex::Regex;
use std::collections::{HashMap, HashSet};
use thiserror::Error;

use super::schema::{RouteAction, TenantsFile};

/// Structured validation error with a field path and a human-readable reason.
#[derive(Debug, Error, PartialEq)]
pub enum ValidationError {
    #[error("schema_version {version} is unsupported; expected 1")]
    UnsupportedSchemaVersion { version: u32 },

    #[error("tenant[{id}].id: invalid format — must match ^[a-z0-9][a-z0-9-]{{1,30}}[a-z0-9]$")]
    InvalidTenantId { id: String },

    #[error("tenant[{id}].domains[{domain}]: invalid hostname format")]
    InvalidDomain { id: String, domain: String },

    #[error("tenant[{id}]: duplicate tenant id")]
    DuplicateTenantId { id: String },

    #[error("domain '{domain}' claimed by both tenant '{a}' and tenant '{b}'")]
    DomainCollision {
        domain: String,
        a: String,
        b: String,
    },

    #[error("tenant[{id}].routes[{index}].path: must be non-empty and start with '/'")]
    InvalidRoutePath { id: String, index: usize },

    #[error("tenant[{id}].routes[{index}] (proxy): upstream is required and must be non-empty")]
    ProxyMissingUpstream { id: String, index: usize },

    #[error(
        "tenant[{id}].routes[{index}] (file_server): root is required, non-empty, and must be an absolute path"
    )]
    FileServerInvalidRoot { id: String, index: usize },
}

/// Validate a parsed [`TenantsFile`].
///
/// Returns `Ok(())` when all checks pass, otherwise `Err(errors)` with the
/// **complete** list of violations.
pub fn validate(file: &TenantsFile) -> Result<(), Vec<ValidationError>> {
    let mut errors: Vec<ValidationError> = Vec::new();

    // schema_version
    if file.schema_version != 1 {
        errors.push(ValidationError::UnsupportedSchemaVersion {
            version: file.schema_version,
        });
    }

    let tenant_id_re = Regex::new(r"^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$").expect("static regex");
    let domain_re = Regex::new(r"^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$")
        .expect("static regex");

    let mut seen_ids: HashSet<String> = HashSet::new();
    // domain → first-claiming tenant id
    let mut seen_domains: HashMap<String, String> = HashMap::new();

    for tenant in &file.tenants {
        let tid = &tenant.id;

        // duplicate id check
        if seen_ids.contains(tid) {
            errors.push(ValidationError::DuplicateTenantId { id: tid.clone() });
        } else {
            seen_ids.insert(tid.clone());
        }

        // tenant id format
        if !tenant_id_re.is_match(tid) {
            errors.push(ValidationError::InvalidTenantId { id: tid.clone() });
        }

        // domain checks
        for domain in &tenant.domains {
            if !domain_re.is_match(domain) {
                errors.push(ValidationError::InvalidDomain {
                    id: tid.clone(),
                    domain: domain.clone(),
                });
            }
            if let Some(prior) = seen_domains.get(domain) {
                if prior != tid {
                    errors.push(ValidationError::DomainCollision {
                        domain: domain.clone(),
                        a: prior.clone(),
                        b: tid.clone(),
                    });
                }
            } else {
                seen_domains.insert(domain.clone(), tid.clone());
            }
        }

        // route checks
        for (idx, route) in tenant.routes.iter().enumerate() {
            if route.path.is_empty() || !route.path.starts_with('/') {
                errors.push(ValidationError::InvalidRoutePath {
                    id: tid.clone(),
                    index: idx,
                });
            }
            match &route.action {
                RouteAction::Proxy { upstream, .. } => {
                    if upstream.is_empty() {
                        errors.push(ValidationError::ProxyMissingUpstream {
                            id: tid.clone(),
                            index: idx,
                        });
                    }
                }
                RouteAction::FileServer { root, .. } => {
                    if root.is_empty() || !root.starts_with('/') {
                        errors.push(ValidationError::FileServerInvalidRoot {
                            id: tid.clone(),
                            index: idx,
                        });
                    }
                }
            }
        }
    }

    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors)
    }
}
