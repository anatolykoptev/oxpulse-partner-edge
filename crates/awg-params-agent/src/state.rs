//! Persistent state: last-applied epoch + timestamp.
//! Written atomically to avoid corrupt reads on crash.

use crate::error::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::io::Write;
use std::path::Path;
use tempfile::NamedTempFile;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AwgState {
    pub last_applied_epoch: i64,
    pub applied_at: DateTime<Utc>,
}

/// Load state from `path`. Returns `Ok(None)` if the file does not exist yet
/// (fresh install — treat as epoch 0).
pub fn load_state(path: &Path) -> Result<Option<AwgState>> {
    match std::fs::read_to_string(path) {
        Ok(s) => {
            let state: AwgState =
                serde_json::from_str(&s).with_context(|| format!("parse state file {:?}", path))?;
            Ok(Some(state))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e).with_context(|| format!("read state file {:?}", path)),
    }
}

/// Atomically write state to `path` (temp-file in same dir + rename + dir-fsync).
pub fn save_state(path: &Path, state: &AwgState) -> Result<()> {
    let dir = path.parent().unwrap_or(Path::new("."));

    // Ensure the state directory exists (first run on a fresh install).
    std::fs::create_dir_all(dir).with_context(|| format!("create state dir {:?}", dir))?;

    let json = serde_json::to_string_pretty(state).context("serialize state")?;

    let mut tmp = NamedTempFile::new_in(dir).with_context(|| format!("create tmp in {:?}", dir))?;
    tmp.write_all(json.as_bytes()).context("write state tmp")?;
    tmp.flush().context("flush state tmp")?;
    tmp.as_file().sync_all().context("fsync state tmp")?;
    tmp.persist(path)
        .with_context(|| format!("persist state to {:?}", path))?;

    // fsync directory so rename is durable across crash.
    if let Ok(d) = std::fs::File::open(dir) {
        let _ = d.sync_all();
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn load_save_roundtrip() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("awg-params-state.json");

        // Non-existent → None.
        assert!(load_state(&path).unwrap().is_none());

        let state = AwgState {
            last_applied_epoch: 42,
            applied_at: Utc::now(),
        };
        save_state(&path, &state).unwrap();

        let loaded = load_state(&path)
            .unwrap()
            .expect("state should exist after save");
        assert_eq!(loaded.last_applied_epoch, state.last_applied_epoch);
        // Timestamp survives roundtrip within 1ms (serde_json uses RFC3339).
        let diff = (loaded.applied_at - state.applied_at)
            .num_milliseconds()
            .abs();
        assert!(diff < 1, "timestamp drift: {}ms", diff);
    }
}
