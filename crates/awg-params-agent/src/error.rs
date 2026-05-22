// Error module: re-export anyhow for a unified error surface.
// All functions in this crate return `anyhow::Result<T>`.
// Individual error categories are conveyed via context strings.
pub use anyhow::{anyhow, Context, Result};
