//! SVC (Scalable Video Coding) forwarding support.
//!
//! G3 phases:
//! * **P0** (merged): enable Dependency Descriptor (DD) RTP header-extension
//!   parsing as observability-only — register the str0m `ExtensionSerializer`
//!   seam, mark DD presence on ingress `MediaData`, count it. No bit-parsing,
//!   no layer drop.
//! * **P1** (this phase): full DD bit-parser ([`dd_parse`]) resolving
//!   `temporal_id` per frame, a per-stream structure cache ([`dd_ext`]'s
//!   `DdStructureCache`) for template-only DDs, and per-subscriber temporal-
//!   layer drop in the fanout. Spatial drop / chain / decode-target integrity
//!   is P2.
//!
//! The DD is a cleartext RTP header extension readable under SFrame (RFC 9605)
//! E2EE because we do not perform CryptEx / RFC 9335 header-extension
//! encryption. See [`dd_ext`] for the extension seam and [`dd_parse`] for the
//! pure bit-parser.

pub mod dd_ext;
pub mod dd_parse;

pub use dd_ext::{DdPresent, DdSerializer, DdStructureCache, DD_URI};
pub use dd_parse::{
    parse_dependency_descriptor, DependencyDescriptor, FrameDependencyTemplate,
    TemplateDependencyStructure,
};
