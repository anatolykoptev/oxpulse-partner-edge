//! UDP-loop metrics — packet send observability for the SFU media plane.
//!
//! Concern: the SFU writes RTP/RTCP to clients via a single shared
//! `UdpSocket::send_to`. When the destination address becomes
//! transiently invalid (peer's WireGuard tunnel flaps, NAT mapping
//! expires, OS routing table mutates mid-connection), `send_to`
//! returns `EDESTADDRREQ` / `ENETUNREACH` / `EHOSTUNREACH` / `EAGAIN`.
//! Without metrics these only show up in tracing logs and we cannot
//! detect ratio spikes without grepping.
//!
//! Bounded label set per the design rule: never let unbounded values
//! flow into Prometheus labels. The OS-error matrix is large but every
//! observable case here maps to one of seven buckets.

use anyhow::Context;
use prometheus::{IntCounter, IntCounterVec, Opts, Registry};

/// Bundle returned by [`register`].
pub(super) struct UdpMetrics {
    pub packets_sent_total: IntCounter,
    /// labels: kind ∈ {dest_required, host_unreachable, network_unreachable,
    /// permission_denied, would_block, broken_pipe, other}.
    pub send_errors_total: IntCounterVec,
}

/// Map an [`std::io::Error`] kind+raw-os-error to a bounded label.
///
/// The mapping prefers OS errno over `io::ErrorKind` when both are
/// available, because `ErrorKind::Other` is the default for unknown
/// errno values and we want to distinguish them at the label level.
pub fn classify_send_error(err: &std::io::Error) -> &'static str {
    if let Some(code) = err.raw_os_error() {
        match code {
            89 => return "dest_required",     // EDESTADDRREQ
            101 | 51 => return "network_unreachable", // ENETUNREACH (Linux 101, BSD 51)
            113 | 65 => return "host_unreachable",    // EHOSTUNREACH (Linux 113, BSD 65)
            13 => return "permission_denied",         // EACCES
            11 | 35 => return "would_block",          // EAGAIN/EWOULDBLOCK
            32 => return "broken_pipe",               // EPIPE
            _ => {}
        }
    }
    match err.kind() {
        std::io::ErrorKind::WouldBlock => "would_block",
        std::io::ErrorKind::PermissionDenied => "permission_denied",
        std::io::ErrorKind::BrokenPipe => "broken_pipe",
        std::io::ErrorKind::ConnectionRefused
        | std::io::ErrorKind::ConnectionReset
        | std::io::ErrorKind::ConnectionAborted => "host_unreachable",
        _ => "other",
    }
}

/// Construct and register the UDP-loop metrics onto the SFU registry.
pub(super) fn register(registry: &Registry) -> anyhow::Result<UdpMetrics> {
    macro_rules! reg {
        ($m:expr) => {{
            let m = $m;
            registry
                .register(Box::new(m.clone()))
                .context("metric registration")?;
            m
        }};
    }

    let packets_sent_total = reg!(IntCounter::with_opts(Opts::new(
        "udp_packets_sent_total",
        "RTP/RTCP packets dispatched via send_to (denominator for udp_send_errors_total)",
    ))
    .context("udp_packets_sent_total")?);

    let send_errors_total = reg!(IntCounterVec::new(
        Opts::new(
            "udp_send_errors_total",
            "send_to errors classified by errno (broken NAT/WireGuard mappings surface here)",
        ),
        &["kind"],
    )
    .context("udp_send_errors_total")?);

    Ok(UdpMetrics {
        packets_sent_total,
        send_errors_total,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn err_with_os(code: i32) -> std::io::Error {
        std::io::Error::from_raw_os_error(code)
    }

    #[test]
    fn classify_dest_required_from_errno_89() {
        assert_eq!(classify_send_error(&err_with_os(89)), "dest_required");
    }

    #[test]
    fn classify_network_unreachable_linux_and_bsd() {
        assert_eq!(classify_send_error(&err_with_os(101)), "network_unreachable");
        assert_eq!(classify_send_error(&err_with_os(51)), "network_unreachable");
    }

    #[test]
    fn classify_host_unreachable_linux_and_bsd() {
        assert_eq!(classify_send_error(&err_with_os(113)), "host_unreachable");
        assert_eq!(classify_send_error(&err_with_os(65)), "host_unreachable");
    }

    #[test]
    fn classify_would_block_linux_and_bsd() {
        assert_eq!(classify_send_error(&err_with_os(11)), "would_block");
        assert_eq!(classify_send_error(&err_with_os(35)), "would_block");
    }

    #[test]
    fn classify_unknown_errno_falls_back_to_kind() {
        // errno 9999 has no specific match — falls through to the
        // ErrorKind matcher. `from_raw_os_error` constructs an Other.
        let label = classify_send_error(&err_with_os(9999));
        assert_eq!(label, "other");
    }

    #[test]
    fn classify_kind_only_error_when_no_errno() {
        let err = std::io::Error::new(std::io::ErrorKind::WouldBlock, "test");
        assert_eq!(classify_send_error(&err), "would_block");
    }

    #[test]
    fn register_succeeds_on_fresh_registry() {
        let registry = Registry::new();
        let m = register(&registry).expect("register must succeed");
        m.packets_sent_total.inc();
        m.send_errors_total.with_label_values(&["dest_required"]).inc();
        assert_eq!(m.packets_sent_total.get(), 1);
    }
}
