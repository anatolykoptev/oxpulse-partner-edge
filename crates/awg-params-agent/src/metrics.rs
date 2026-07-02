//! Prometheus textfile-collector metrics for awg-params-agent (Task 12).
//!
//! Emits ONE node_exporter textfile-collector file ([`PROM_FILE`] under the
//! configured `textfile_dir`) covering every series this crate exports:
//!   * `awg_params_agent_poll_failures_total` — non-2xx/network-error GETs of
//!     `.../awg-params/latest` (central-unreachable signal).
//!   * `awg_params_agent_last_success_timestamp_seconds` — gauge, unix time
//!     of the last 2xx poll. `0` = never succeeded since a fresh install (no
//!     prior file to reseed from) — deliberately maximal staleness so a node
//!     that has NEVER reached central alerts immediately, not after a grace
//!     window keyed off process start.
//!   * `awg_params_agent_conf_write_conflicts_total{reason=...}` — migrated
//!     here from the interim implementation that used to live in `agent.rs`
//!     (see [`ConflictReason`]); same two reasons, same semantics.
//!   * `awg_params_agent_param_rejected_total{field=...}` — central-sourced
//!     obfuscation params rejected by `AwgParams::validate()` before splice
//!     into awg0.conf (params.rs, T4 crypto_invariant). Non-zero is a
//!     hostile-central / MITM signal — critical alert, not routine.
//!
//! Convention matches the sibling `oxpulse-partner-edge-refresh.sh`'s
//! `emit_metric` (temp-file + atomic rename under `textfile_dir`) — this
//! module is the Rust-agent equivalent of that shell helper, consolidated
//! into one file so node_exporter always scrapes a complete, self-consistent
//! snapshot (never a partial write, never two competing writers of the same
//! series).
//!
//! A dedicated textfile exporter (not an HTTP `/metrics` server): the agent
//! is a lightweight host daemon, and node_exporter's textfile collector is
//! the established low-footprint convention this repo already uses for
//! `oxpulse-partner-edge-refresh.sh`.

use crate::error::{Context, Result};
use chrono::Utc;
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::Mutex;
use tempfile::NamedTempFile;

/// Filename written under `textfile_dir` for ALL awg-params-agent series.
pub const PROM_FILE: &str = "awg_params_agent.prom";

pub(crate) const POLL_FAILURES_METRIC: &str = "awg_params_agent_poll_failures_total";
pub(crate) const LAST_SUCCESS_METRIC: &str = "awg_params_agent_last_success_timestamp_seconds";
pub(crate) const CONF_CONFLICT_METRIC: &str = "awg_params_agent_conf_write_conflicts_total";
pub(crate) const PARAM_REJECTED_METRIC: &str = "awg_params_agent_param_rejected_total";

/// Max distinct `field=` labels tracked for `param_rejected_total`. Defensive
/// cardinality cap — the label always comes from THIS crate's own
/// `validate()` error text (params.rs), never central-sourced content
/// directly, so today's real ceiling is 1 (`"i1"`); this bounds future
/// growth rather than responding to an attacker-controlled label.
const MAX_PARAM_REJECTED_FIELDS: usize = 16;

/// Why the agent skipped an awg0.conf write/apply this tick. Each maps to its
/// own `reason=` label on [`CONF_CONFLICT_METRIC`] so the two mechanics stay
/// distinguishable — they represent very different operational states:
///   * `LockTimeout` — the agent could not acquire the shared lock within the
///     timeout and never touched awg0.conf at all. Sustained occurrence is
///     escalation-worthy (a writer is monopolizing the lock).
///   * `ApplySuperseded` — the agent DID write under the lock, but the
///     installer superseded the file before the (deliberately unlocked)
///     kernel apply, so only the apply was deferred one poll. Expected and
///     self-healing during any install/rotation window; routine, not
///     escalation-worthy.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum ConflictReason {
    LockTimeout,
    ApplySuperseded,
}

impl ConflictReason {
    /// All reasons, so callers (seed + emit) enumerate the full label set.
    const ALL: [ConflictReason; 2] = [ConflictReason::LockTimeout, ConflictReason::ApplySuperseded];

    fn label(self) -> &'static str {
        match self {
            ConflictReason::LockTimeout => "lock_timeout",
            ConflictReason::ApplySuperseded => "apply_superseded",
        }
    }

    /// Fully-qualified series prefix, e.g.
    /// `awg_params_agent_conf_write_conflicts_total{reason="lock_timeout"}`.
    fn series_prefix(self) -> String {
        format!("{CONF_CONFLICT_METRIC}{{reason=\"{}\"}}", self.label())
    }
}

#[derive(Default)]
struct ConflictCounts {
    lock_timeout: u64,
    apply_superseded: u64,
}

impl ConflictCounts {
    fn set(&mut self, reason: ConflictReason, value: u64) {
        match reason {
            ConflictReason::LockTimeout => self.lock_timeout = value,
            ConflictReason::ApplySuperseded => self.apply_superseded = value,
        }
    }
}

/// Extract the `field=<name>` marker from an error's full source chain — not
/// just the top-level message, since `merge_and_write_conf_locked` wraps the
/// raw `validate()` error in additional `.context(...)` frames before it
/// reaches the caller. Returns `None` when no frame in the chain carries the
/// marker (the normal case for every non-validation error).
///
/// Public so it is independently unit-testable against the REAL
/// `params::validate_i1` error shape rather than a hand-copied string.
pub(crate) fn extract_rejected_field(err: &anyhow::Error) -> Option<String> {
    const MARKER: &str = "field=";
    for cause in err.chain() {
        let text = cause.to_string();
        if let Some(idx) = text.find(MARKER) {
            let field: String = text[idx + MARKER.len()..]
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
                .collect();
            if !field.is_empty() {
                return Some(field);
            }
        }
    }
    None
}

/// Process-lifetime metric state for awg-params-agent, mirrored to
/// [`PROM_FILE`] after every recorded event. Reseeded from that file on
/// construction so counters stay monotonic across daemon restarts (matches
/// the restart-monotonicity guarantee the interim conflict counter already
/// had).
pub(crate) struct Metrics {
    dir: PathBuf,
    poll_failures: AtomicU64,
    last_success_epoch_secs: AtomicI64,
    conf_write_conflicts_lock_timeout: AtomicU64,
    conf_write_conflicts_apply_superseded: AtomicU64,
    param_rejected: Mutex<BTreeMap<String, u64>>,
}

impl Metrics {
    /// Load process-lifetime state from `dir`'s existing [`PROM_FILE`], if
    /// any. Best-effort: a missing or unparseable file yields all-zero state
    /// (fresh start) rather than an error.
    pub(crate) fn load(dir: &Path) -> Self {
        let mut poll_failures = 0u64;
        let mut last_success = 0i64;
        let mut conflicts = ConflictCounts::default();
        let mut param_rejected = BTreeMap::new();

        if let Ok(text) = std::fs::read_to_string(dir.join(PROM_FILE)) {
            for line in text.lines() {
                let line = line.trim();
                if line.is_empty() || line.starts_with('#') {
                    continue;
                }
                let Some((series, value)) = line.rsplit_once(' ') else {
                    continue;
                };
                if series == POLL_FAILURES_METRIC {
                    if let Ok(n) = value.parse() {
                        poll_failures = n;
                    }
                } else if series == LAST_SUCCESS_METRIC {
                    if let Ok(n) = value.parse() {
                        last_success = n;
                    }
                } else if let Some(reason) = ConflictReason::ALL
                    .iter()
                    .find(|r| series == r.series_prefix())
                {
                    if let Ok(n) = value.parse() {
                        conflicts.set(*reason, n);
                    }
                } else if let Some(field) = series
                    .strip_prefix(&format!("{PARAM_REJECTED_METRIC}{{field=\""))
                    .and_then(|s| s.strip_suffix("\"}"))
                {
                    if let Ok(n) = value.parse::<u64>() {
                        param_rejected.insert(field.to_owned(), n);
                    }
                }
            }
        }

        Self {
            dir: dir.to_owned(),
            poll_failures: AtomicU64::new(poll_failures),
            last_success_epoch_secs: AtomicI64::new(last_success),
            conf_write_conflicts_lock_timeout: AtomicU64::new(conflicts.lock_timeout),
            conf_write_conflicts_apply_superseded: AtomicU64::new(conflicts.apply_superseded),
            param_rejected: Mutex::new(param_rejected),
        }
    }

    /// Bump `poll_failures_total` and flush. Called on a non-2xx or
    /// network-error response from `GET .../awg-params/latest` — the
    /// central-unreachable signal this task exists to surface.
    pub(crate) fn record_poll_failure(&self) -> Result<()> {
        self.poll_failures.fetch_add(1, Ordering::Relaxed);
        self.flush()
    }

    /// Set `last_success_timestamp_seconds` to now and flush. Called on a 2xx
    /// response — advances the gauge so a staleness alert (`time() - gauge >
    /// N`) clears.
    pub(crate) fn record_poll_success(&self) -> Result<()> {
        self.last_success_epoch_secs
            .store(Utc::now().timestamp(), Ordering::Relaxed);
        self.flush()
    }

    /// Bump the conf-write-conflict counter for `reason` and flush. See
    /// [`ConflictReason`] for the two reasons' semantics.
    pub(crate) fn record_conf_write_conflict(&self, reason: ConflictReason) -> Result<()> {
        match reason {
            ConflictReason::LockTimeout => {
                self.conf_write_conflicts_lock_timeout
                    .fetch_add(1, Ordering::Relaxed);
            }
            ConflictReason::ApplySuperseded => {
                self.conf_write_conflicts_apply_superseded
                    .fetch_add(1, Ordering::Relaxed);
            }
        }
        self.flush()
    }

    /// Bump `param_rejected_total{field}` and flush. `field` is capped at
    /// [`MAX_PARAM_REJECTED_FIELDS`] distinct values — beyond the cap, a new
    /// field is dropped silently (existing fields keep counting normally).
    pub(crate) fn record_param_rejected(&self, field: &str) -> Result<()> {
        let should_flush = {
            let mut map = self
                .param_rejected
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if !map.contains_key(field) && map.len() >= MAX_PARAM_REJECTED_FIELDS {
                false
            } else {
                *map.entry(field.to_owned()).or_insert(0) += 1;
                true
            }
        };
        if should_flush {
            self.flush()
        } else {
            Ok(())
        }
    }

    /// Atomically rewrite [`PROM_FILE`] with a complete, self-consistent
    /// snapshot of every series. Temp file + rename + dir-fsync, matching
    /// `agent.rs`'s `write_conf_atomic` crash-safety pattern.
    fn flush(&self) -> Result<()> {
        let poll_failures = self.poll_failures.load(Ordering::Relaxed);
        let last_success = self.last_success_epoch_secs.load(Ordering::Relaxed);
        let lock_timeout = self
            .conf_write_conflicts_lock_timeout
            .load(Ordering::Relaxed);
        let apply_superseded = self
            .conf_write_conflicts_apply_superseded
            .load(Ordering::Relaxed);
        let rejected = self
            .param_rejected
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone();

        std::fs::create_dir_all(&self.dir)
            .with_context(|| format!("create textfile dir {:?}", self.dir))?;

        let mut body = String::new();
        body.push_str(&format!(
            "# HELP {m} Non-2xx or network-error responses from GET .../awg-params/latest \
             (central-unreachable signal), cumulative since agent start (reseeded from this \
             file on restart).\n# TYPE {m} counter\n{m} {poll_failures}\n",
            m = POLL_FAILURES_METRIC,
        ));
        body.push_str(&format!(
            "# HELP {m} Unix timestamp of the last successful (2xx) poll of central. \
             0 = never succeeded since install (fresh node, no prior file to reseed from) — \
             alert on `time() - {m} > N` for staleness.\n# TYPE {m} gauge\n{m} {last_success}\n",
            m = LAST_SUCCESS_METRIC,
        ));
        body.push_str(&format!(
            "# HELP {m} awg0.conf writes/applies the agent skipped due to a concurrent \
             writer, by reason. reason=\"lock_timeout\": could not acquire the shared lock \
             within the timeout, so the agent never wrote awg0.conf (retries next poll). \
             reason=\"apply_superseded\": wrote under the lock, but the installer superseded \
             the file before the unlocked kernel apply, so only the apply was deferred to the \
             next poll (self-healing).\n# TYPE {m} counter\n{lt_series} {lock_timeout}\n\
             {as_series} {apply_superseded}\n",
            m = CONF_CONFLICT_METRIC,
            lt_series = ConflictReason::LockTimeout.series_prefix(),
            as_series = ConflictReason::ApplySuperseded.series_prefix(),
        ));
        body.push_str(&format!(
            "# HELP {m} Central-sourced obfuscation params rejected by validate() before \
             splice into awg0.conf, by field (see params.rs I1 conf-injection guard). \
             Non-zero is a hostile-central / MITM signal — critical alert, not routine.\n\
             # TYPE {m} counter\n",
            m = PARAM_REJECTED_METRIC,
        ));
        for (field, count) in &rejected {
            body.push_str(&format!(
                "{PARAM_REJECTED_METRIC}{{field=\"{field}\"}} {count}\n"
            ));
        }

        let mut tmp = NamedTempFile::new_in(&self.dir)
            .with_context(|| format!("temp textfile in {:?}", self.dir))?;
        tmp.write_all(body.as_bytes())
            .context("write metrics textfile")?;
        tmp.flush().context("flush metrics textfile")?;
        tmp.persist(self.dir.join(PROM_FILE))
            .context("persist metrics textfile")?;
        // dir-fsync: best-effort durability of the rename across a crash.
        if let Ok(d) = std::fs::File::open(&self.dir) {
            let _ = d.sync_all();
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_rejected_field_finds_field_in_real_validate_i1_error_chain() {
        // Exercises the REAL params::validate_i1 (not a hand-copied error
        // string), wrapped exactly as conf_merge::merge_obfuscation_params
        // wraps it — proves the parser matches the actual shipped chain.
        let base = crate::params::validate_i1("bad\n[Peer]").unwrap_err();
        let wrapped = base.context("merge obfuscation params");
        assert_eq!(
            extract_rejected_field(&wrapped).as_deref(),
            Some("i1"),
            "must find field=i1 even when wrapped in an outer context frame"
        );
    }

    #[test]
    fn extract_rejected_field_none_when_absent() {
        let err = anyhow::anyhow!("some unrelated failure");
        assert_eq!(extract_rejected_field(&err), None);
    }

    #[test]
    fn poll_failure_then_success_updates_series_independently() {
        let dir = tempfile::tempdir().unwrap();
        let metrics = Metrics::load(dir.path());

        metrics.record_poll_failure().unwrap();
        let prom = std::fs::read_to_string(dir.path().join(PROM_FILE)).unwrap();
        assert!(
            prom.contains(&format!("{POLL_FAILURES_METRIC} 1")),
            "poll failure must bump poll_failures_total. Got:\n{prom}"
        );
        assert!(
            prom.contains(&format!("{LAST_SUCCESS_METRIC} 0")),
            "last_success must stay at the never-succeeded sentinel (0) after only a \
             failure. Got:\n{prom}"
        );

        metrics.record_poll_success().unwrap();
        let prom = std::fs::read_to_string(dir.path().join(PROM_FILE)).unwrap();
        let ts_line = prom
            .lines()
            .find(|l| l.starts_with(LAST_SUCCESS_METRIC))
            .expect("last_success series must be present");
        let ts: i64 = ts_line
            .rsplit(' ')
            .next()
            .and_then(|v| v.parse().ok())
            .expect("last_success value must parse");
        assert!(
            ts > 0,
            "last_success_timestamp must advance off the 0 sentinel on a real success. \
             Got line: {ts_line:?}"
        );
        // poll_failures must be untouched by a subsequent success — the two
        // series are independent, a success does not clear the failure count.
        assert!(
            prom.contains(&format!("{POLL_FAILURES_METRIC} 1")),
            "a later success must not reset poll_failures_total. Got:\n{prom}"
        );
    }

    #[test]
    fn param_rejected_caps_at_max_distinct_fields() {
        let dir = tempfile::tempdir().unwrap();
        let metrics = Metrics::load(dir.path());
        for i in 0..MAX_PARAM_REJECTED_FIELDS + 5 {
            metrics.record_param_rejected(&format!("f{i}")).unwrap();
        }
        let prom = std::fs::read_to_string(dir.path().join(PROM_FILE)).unwrap();
        let series_count = prom
            .lines()
            .filter(|l| l.starts_with(&format!("{PARAM_REJECTED_METRIC}{{")))
            .count();
        assert_eq!(
            series_count, MAX_PARAM_REJECTED_FIELDS,
            "distinct param_rejected fields must be capped at {MAX_PARAM_REJECTED_FIELDS}. \
             Got {series_count} series in:\n{prom}"
        );
    }

    #[test]
    fn metrics_reseed_from_disk_across_restart() {
        let dir = tempfile::tempdir().unwrap();
        {
            let m = Metrics::load(dir.path());
            m.record_poll_failure().unwrap();
            m.record_poll_failure().unwrap();
            m.record_conf_write_conflict(ConflictReason::LockTimeout)
                .unwrap();
            m.record_param_rejected("i1").unwrap();
        }
        let m2 = Metrics::load(dir.path());
        m2.record_poll_failure().unwrap();
        let prom = std::fs::read_to_string(dir.path().join(PROM_FILE)).unwrap();
        assert!(
            prom.contains(&format!("{POLL_FAILURES_METRIC} 3")),
            "poll_failures must resume at seeded 2 then +1 = 3. Got:\n{prom}"
        );
        assert!(
            prom.contains(&format!(
                "{CONF_CONFLICT_METRIC}{{reason=\"lock_timeout\"}} 1"
            )),
            "conf_write_conflicts must reseed. Got:\n{prom}"
        );
        assert!(
            prom.contains(&format!("{PARAM_REJECTED_METRIC}{{field=\"i1\"}} 1")),
            "param_rejected must reseed. Got:\n{prom}"
        );
    }
}
