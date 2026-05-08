/// Inject `a=msid:peer-<peer_id> peer-<peer_id>-<kind>` into every m-line of
/// the answer SDP that has a non-recvonly direction.
///
/// str0m emits random UUID-based msid lines; the browser's bindRemoteTrack
/// needs a deterministic stream ID to associate tracks. This replaces any
/// existing `a=msid:` lines (random or absent) with the canonical
/// `peer-<peer_id>` pattern. Idempotent — m-lines already carrying
/// `a=msid:peer-<peer_id>` are left untouched (re-runs safe).
///
/// Why post-process: str0m 0.18.1 Answer API exposes only `to_sdp_string()` —
/// no per-m-line attribute mutation. Without deterministic msid the browser's
/// RTCPeerConnection.ontrack fires with ev.streams = [] (random IDs are
/// present but oxpulse-chat bindRemoteTrack can't find the stream), causing
/// gc_ontrack_drop_total{reason="empty_stream"} in oxpulse-chat.
pub fn inject_msid(answer_sdp: &str, peer_id: u64) -> String {
    // Detect line ending style (WebRTC SDP uses CRLF per RFC 4566, but
    // str0m may emit LF-only in tests; preserve whatever we received).
    let crlf = answer_sdp.contains("\r\n");
    let eol = if crlf { "\r\n" } else { "\n" };

    #[derive(Clone, Copy, PartialEq)]
    enum Kind {
        Audio,
        Video,
        Other,
    }

    #[derive(Clone, Copy, PartialEq)]
    enum Direction {
        SendOnly,
        SendRecv,
        Inactive,
        RecvOnly,
    }

    // Per-m-line accumulator flushed either on next `m=` or at EOF.
    struct MBlock {
        lines: Vec<String>,
        kind: Kind,
        direction: Direction,
        /// True when `a=msid:peer-<peer_id>` is already present — skip injection.
        /// str0m random-UUID msids are NOT counted; those get stripped and replaced.
        already_injected: bool,
        mid_idx: Option<usize>, // index in `lines` of `a=mid:` line
    }

    impl MBlock {
        fn new(kind: Kind) -> Self {
            Self {
                lines: Vec::new(),
                kind,
                direction: Direction::SendOnly, // default per SDP RFC for answerer
                already_injected: false,
                mid_idx: None,
            }
        }

        /// Flush block lines into `out`, injecting msid after `a=mid:` when
        /// conditions are met. Any pre-existing `a=msid:` lines that are NOT
        /// the canonical `peer-<peer_id>` pattern are stripped so we don't
        /// accumulate both str0m's random UUID msids and our own.
        fn flush(self, out: &mut String, peer_id: u64, eol: &str) {
            if self.kind == Kind::Other
                || self.already_injected
                || self.direction == Direction::RecvOnly
                || self.direction == Direction::Inactive
            {
                // RFC 8829 §5.3.2 — inactive/recvonly m-lines carry no
                // outbound track; injecting a=msid is semantically wrong.
                for l in &self.lines {
                    out.push_str(l);
                    out.push_str(eol);
                }
                return;
            }

            let kind_str = match self.kind {
                Kind::Audio => "audio",
                Kind::Video => "video",
                Kind::Other => unreachable!(),
            };
            let msid_line = format!("a=msid:peer-{peer_id} peer-{peer_id}-{kind_str}");

            // Strip any pre-existing `a=msid:` lines (str0m random UUIDs) —
            // we only keep lines that are NOT `a=msid:` (those were not
            // the canonical peer-N pattern, otherwise `already_injected`
            // would be true and we'd have returned early above).
            //
            // Insert after `a=mid:N` if present, otherwise append before
            // first `a=ssrc:` (or just append at end of block).
            let insert_after = self.mid_idx.unwrap_or_else(|| {
                self.lines
                    .iter()
                    .rposition(|l| !l.starts_with("a=ssrc:"))
                    .unwrap_or(self.lines.len().saturating_sub(1))
            });

            let mut injected = false;
            for (i, l) in self.lines.iter().enumerate() {
                // Drop pre-existing non-canonical msid lines.
                if l.starts_with("a=msid:") {
                    continue;
                }
                out.push_str(l);
                out.push_str(eol);
                if !injected && i == insert_after {
                    out.push_str(&msid_line);
                    out.push_str(eol);
                    injected = true;
                }
            }
            // Edge case: insert_after was past the stripped msid lines.
            if !injected {
                out.push_str(&msid_line);
                out.push_str(eol);
            }
        }
    }

    let mut out = String::with_capacity(answer_sdp.len() + 128);
    let mut session_lines: Vec<String> = Vec::new(); // lines before first m=
    let mut in_session = true;
    let mut current: Option<MBlock> = None;

    let lines: Vec<&str> = if crlf {
        answer_sdp.split("\r\n").collect()
    } else {
        answer_sdp.split('\n').collect()
    };

    for raw in &lines {
        // Trailing split on the last eol gives an empty final element —
        // skip it here; we'll not re-emit it (the blocks do their own eol).
        if raw.is_empty() {
            continue;
        }

        if raw.starts_with("m=") {
            // Flush previous m-block (or session section).
            if in_session {
                for l in &session_lines {
                    out.push_str(l);
                    out.push_str(eol);
                }
                in_session = false;
            } else if let Some(block) = current.take() {
                block.flush(&mut out, peer_id, eol);
            }

            let kind = if raw.starts_with("m=audio") {
                Kind::Audio
            } else if raw.starts_with("m=video") {
                Kind::Video
            } else {
                Kind::Other
            };
            let mut block = MBlock::new(kind);
            block.lines.push(raw.to_string());
            current = Some(block);
        } else if in_session {
            session_lines.push(raw.to_string());
        } else if let Some(ref mut block) = current {
            // Detect direction.
            match *raw {
                "a=recvonly" => block.direction = Direction::RecvOnly,
                "a=sendonly" => block.direction = Direction::SendOnly,
                "a=sendrecv" => block.direction = Direction::SendRecv,
                "a=inactive" => block.direction = Direction::Inactive,
                _ => {}
            }
            // Only treat as already-injected if it's our canonical peer-N pattern.
            if raw.starts_with(&format!("a=msid:peer-{peer_id} ")) {
                block.already_injected = true;
            }
            if raw.starts_with("a=mid:") {
                block.mid_idx = Some(block.lines.len()); // index of THIS line (pushed next)
            }
            block.lines.push(raw.to_string());
        }
    }

    // Flush last block.
    if in_session {
        for l in &session_lines {
            out.push_str(l);
            out.push_str(eol);
        }
    } else if let Some(block) = current {
        block.flush(&mut out, peer_id, eol);
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn audio_video_sdp() -> &'static str {
        "v=0\r\n\
         o=- 0 0 IN IP4 127.0.0.1\r\n\
         s=-\r\n\
         t=0 0\r\n\
         m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n\
         a=mid:0\r\n\
         a=sendonly\r\n\
         a=rtpmap:111 opus/48000/2\r\n\
         m=video 9 UDP/TLS/RTP/SAVPF 96\r\n\
         a=mid:1\r\n\
         a=sendonly\r\n\
         a=rtpmap:96 VP8/90000\r\n"
    }

    #[test]
    fn injects_msid_per_audio_video_mline() {
        let result = inject_msid(audio_video_sdp(), 7);
        assert!(
            result.contains("a=msid:peer-7 peer-7-audio"),
            "audio msid missing; got:\n{result}"
        );
        assert!(
            result.contains("a=msid:peer-7 peer-7-video"),
            "video msid missing; got:\n{result}"
        );
    }

    #[test]
    fn idempotent_when_canonical_msid_already_present() {
        // Re-running inject_msid on already-injected SDP must not duplicate.
        let sdp = "v=0\r\n\
                   o=- 0 0 IN IP4 127.0.0.1\r\n\
                   s=-\r\n\
                   t=0 0\r\n\
                   m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n\
                   a=mid:0\r\n\
                   a=sendonly\r\n\
                   a=msid:peer-7 peer-7-audio\r\n\
                   a=rtpmap:111 opus/48000/2\r\n";
        let result = inject_msid(sdp, 7);
        let msid_count = result.matches("a=msid:").count();
        assert_eq!(msid_count, 1, "canonical msid duplicated; got:\n{result}");
        assert!(
            result.contains("a=msid:peer-7 peer-7-audio"),
            "canonical msid removed; got:\n{result}"
        );
    }

    #[test]
    fn replaces_random_msid_from_str0m() {
        // str0m emits random UUID msids; we replace them with deterministic peer-N.
        let sdp = "v=0\r\n\
                   o=- 0 0 IN IP4 127.0.0.1\r\n\
                   s=-\r\n\
                   t=0 0\r\n\
                   m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n\
                   a=mid:0\r\n\
                   a=sendonly\r\n\
                   a=msid:randomUUID trackUUID\r\n\
                   a=rtpmap:111 opus/48000/2\r\n";
        let result = inject_msid(sdp, 7);
        assert!(
            result.contains("a=msid:peer-7 peer-7-audio"),
            "peer-7 msid not injected; got:\n{result}"
        );
        assert!(
            !result.contains("a=msid:randomUUID"),
            "random msid not stripped; got:\n{result}"
        );
    }

    #[test]
    fn skips_recvonly_mlines() {
        let sdp = "v=0\r\n\
                   o=- 0 0 IN IP4 127.0.0.1\r\n\
                   s=-\r\n\
                   t=0 0\r\n\
                   m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n\
                   a=mid:0\r\n\
                   a=recvonly\r\n\
                   a=rtpmap:111 opus/48000/2\r\n\
                   m=video 9 UDP/TLS/RTP/SAVPF 96\r\n\
                   a=mid:1\r\n\
                   a=sendrecv\r\n\
                   a=rtpmap:96 VP8/90000\r\n";
        let result = inject_msid(sdp, 7);
        assert!(
            !result.contains("a=msid:peer-7 peer-7-audio"),
            "recvonly audio got msid injected; got:\n{result}"
        );
        assert!(
            result.contains("a=msid:peer-7 peer-7-video"),
            "sendrecv video missing msid; got:\n{result}"
        );
    }

    #[test]
    fn skips_inactive_mlines() {
        // Per RFC 8829 §5.3.2 — inactive m-line carries no media in either
        // direction; injecting a=msid is semantically wrong and rejected by
        // some browsers.
        let sdp = "v=0\r\n\
m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n\
a=mid:0\r\n\
a=inactive\r\n";
        let result = inject_msid(sdp, 7);
        assert!(
            !result.contains("a=msid:peer-7"),
            "inactive m-line must not get a=msid; got:\n{result}"
        );
    }

    #[test]
    fn unknown_kind_skipped() {
        let sdp = "v=0\r\n\
                   o=- 0 0 IN IP4 127.0.0.1\r\n\
                   s=-\r\n\
                   t=0 0\r\n\
                   m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n\
                   a=mid:2\r\n\
                   a=sendrecv\r\n";
        let result = inject_msid(sdp, 7);
        assert!(
            !result.contains("a=msid:"),
            "datachannel m-line got msid injected; got:\n{result}"
        );
    }

    #[test]
    fn peer_id_zero_works() {
        let result = inject_msid(audio_video_sdp(), 0);
        assert!(
            result.contains("a=msid:peer-0 peer-0-audio"),
            "peer_id=0 audio msid missing; got:\n{result}"
        );
        assert!(
            result.contains("a=msid:peer-0 peer-0-video"),
            "peer_id=0 video msid missing; got:\n{result}"
        );
    }
}
