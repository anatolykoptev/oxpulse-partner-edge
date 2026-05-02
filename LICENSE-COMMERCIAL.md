# OxPulse Partner Edge — Commercial License

## Default license

`oxpulse-partner-edge` is distributed under the **GNU Affero General Public
License v3.0** (AGPL-3.0). The full text lives in [`LICENSE`](LICENSE) and is
the canonical license for the project. Community deployments, partners
running unmodified or AGPL-compatible modified versions, self-hosters, and
researchers should use the AGPL terms.

Partners deploying the bundle as published — even when the bundle terminates
TLS, runs a tunnel, relays media, or serves an SFU to remote users — **do
not** trigger a commercial license requirement. The AGPL is sufficient for
the standard partner deployment, which is the deliberate trust contract this
repository preserves.

## When a commercial license is needed

Some organizations cannot accept AGPL § 13 ("Remote Network Interaction"),
which extends source-disclosure obligations to network-accessible
modifications. For those cases, OxPulse offers an alternative commercial
license that removes the AGPL obligations in exchange for a negotiated fee.

Typical use cases:

- **Closed-source enterprise integration** — embedding `oxpulse-partner-edge`
  inside a proprietary internal stack where the AGPL's source-disclosure
  reach is incompatible with corporate or government policy.
- **Proprietary forks** — VPN providers, telco operators, or platform
  vendors who want to ship modified versions without publishing the
  modifications.
- **OEM / white-label resale** — bundling the edge node into a commercial
  product or appliance distributed to third parties under a different brand
  and license.

## What the commercial license grants

A commercial license replaces AGPL terms with a negotiated agreement that
typically includes:

- Right to distribute modified versions without source-disclosure under
  AGPL § 13.
- Right to combine with proprietary code under non-copyleft terms.
- Right to sublicense as part of a larger product or appliance.
- Optional: priority support, indemnity, custom SLAs.

The commercial license does **not** affect anyone else's right to use the
project under AGPL-3.0. The two tracks coexist.

## Pricing

Pricing is bespoke and depends on deployment scale, support tier, and
sublicensing scope. Contact us for a quote — pricing is not published in
this repository.

## Contact

Email: **`licensing@oxpulse.chat`**

Please include:

- Organization name and country of incorporation.
- Intended use case (internal deployment, redistributed product, OEM, etc.).
- Approximate scale (number of nodes, end users, channels) if applicable.
- Whether you need indemnity, support SLA, or custom terms.

We respond within five business days.
