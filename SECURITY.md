# Security policy

We treat security reports seriously. This document explains what we cover, how
to report a vulnerability, and how we coordinate disclosure.

## Scope

In scope:

- Source code in this repository (`oxpulse-partner-edge` — Caddy, xray-client,
  coturn, str0m-based SFU, install / hydrate / upgrade scripts, systemd units).
- Infrastructure operated at `oxpulse.chat` (control plane, registration
  endpoints, SNI rotation pool, signaling) when a vulnerability there allows
  attack against partner-edge nodes or their users.
- Partner-deployed nodes that are registered with the OxPulse control plane.

Out of scope:

- Third-party dependencies — please report upstream first
  (Caddy, xray-core, coturn, str0m, container base images). We will track and
  bump once a fix lands. Coordinate with us if a vulnerability affects a
  partner deployment in a non-obvious way.
- Partner-operated nodes that have **not** registered with the OxPulse control
  plane. Those are independent deployments outside our trust roster.
- Social-engineering, phishing of operators, or physical access to partner
  hardware.
- Issues in third-party services that partners may operate alongside (mail
  servers, monitoring stacks, unrelated reverse proxies).

## How to report

Email `security@oxpulse.chat`.

Include:

- A description of the issue and its impact.
- Steps to reproduce, or a proof-of-concept where applicable.
- Affected versions / commits if known.
- Your preferred name for credit, if you want to be acknowledged.

A GPG key for encrypted reports is forthcoming and will be published in this
file once issued. Until then, please send a brief notification by email and we
will reply with a secure channel for the full report.

Please do **not** open public GitHub issues for security reports.

## Disclosure timeline

- **Acknowledgement** within 3 business days.
- **Triage and severity classification** within 10 business days.
- **Fix and coordinated disclosure** within 90 days from initial report for
  most issues.
- **Expedited timeline** for vulnerabilities that are actively exploited or
  trivially exploitable against partner deployments — we aim for a fix and
  advisory in days, not weeks, and will keep the reporter updated.

If a fix requires longer than 90 days we will say so explicitly, explain why,
and agree on an extended timeline with the reporter rather than missing the
deadline silently.

## Safe harbor

We will not pursue legal action against researchers who:

- Make a good-faith effort to avoid privacy violations, service disruption,
  and destruction of data.
- Report the issue privately and give us a reasonable chance to fix it before
  public disclosure (per the timeline above).
- Do not exploit the vulnerability beyond the minimum necessary to demonstrate
  impact.
- Do not access or modify data belonging to other users.

Good-faith research consistent with this policy is authorized; we will treat
it as such, and we will say so to any third party who asks.

## Acknowledgements

Reporters who help us improve the security of the partner-edge network will be
acknowledged in `CHANGELOG.md` for the release that contains the fix, and
listed in a forthcoming `SECURITY-HALL-OF-FAME.md` once we have the first set
of reports to publish. If you prefer to remain anonymous, say so in your
report and we will respect that.

## Independent audit

We welcome independent security audits of this repository — particularly from
researchers and organizations focused on censorship circumvention,
real-time-communication security, and systems that operate under
network-level adversaries. The OTF Red Team Lab and equivalent programs are
explicitly in scope; we will cooperate on reproducing builds, providing test
deployments, and reviewing findings.

If you are planning a structured audit, please reach out at
`security@oxpulse.chat` so we can support the work.
