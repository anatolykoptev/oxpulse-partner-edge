//! SVC (Scalable Video Coding) forwarding support.
//!
//! G3 phases:
//! * **P0** (this phase): enable Dependency Descriptor (DD) RTP header-extension
//!   parsing as observability-only — register the str0m `ExtensionSerializer`
//!   seam, mark DD presence on ingress `MediaData`, count it. No bit-parsing,
//!   no layer drop.
//! * **P1** (future): full DD bit-parser (spatial/temporal ids, DTIs, chains)
//!   and per-subscriber SVC layer selection driven by the DD.
//!
//! The DD is a cleartext RTP header extension readable under SFrame (RFC 9605)
//! E2EE because we do not perform CryptEx / RFC 9335 header-extension
//! encryption. See [`dd_ext`] for the extension seam.

pub mod dd_ext;

pub use dd_ext::{DdPresent, DdSerializer, DD_URI};
