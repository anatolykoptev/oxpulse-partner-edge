# Documentation index

| Document | Description |
|---|---|
| [README](../README.md) | What the edge bundle installs, its components, requirements and ports. |
| [CHANGELOG](../CHANGELOG.md) | Release history, written by release-please from Conventional Commits. |
| [CONTRIBUTING](../CONTRIBUTING.md) | Contribution flow, commit format, the patch-must-match-message rule and the CLA. |
| [SECURITY](../SECURITY.md) | How to report a vulnerability. |
| [CODE_OF_CONDUCT](../CODE_OF_CONDUCT.md) | Contributor Covenant code of conduct. |
| [LICENSE](../LICENSE) | GNU AGPL-3.0 licence text; commercial terms are in LICENSE-COMMERCIAL.md. |
| [ARCHITECTURE](ARCHITECTURE.md) | Public architecture: components, cryptographic boundary, trust model and the anti-filtering layer. |
| [AWG_PARAM_INVARIANT](AWG_PARAM_INVARIANT.md) | Why every edge must run byte-identical AmneziaWG obfuscation parameters to the central node. |
| [FOLLOWUPS](FOLLOWUPS.md) | Open issues and deferred work noted during pull-request reviews. |
| [HOSTING_REQUIREMENTS](HOSTING_REQUIREMENTS.md) | Host configuration expected of operators before running a production node. |
| [ROADMAP](ROADMAP.md) | Security and operations roadmap by phase. |
| [THREAT-MODEL](THREAT-MODEL.md) | Threat model for the edge bundle: assets, adversaries and mitigations. |
| [adr/ADR-001-converge-engine-contract](adr/ADR-001-converge-engine-contract.md) | Decision for a converge engine that renders and applies managed surfaces idempotently. |
| [adr/ADR-002-state-schema-v1](adr/ADR-002-state-schema-v1.md) | Decision on the versioned state file and its forward migration. |
| [adr/ADR-003-manifest-format](adr/ADR-003-manifest-format.md) | Decision to declare every managed surface in manifest.yaml. |
| [adr/ADR-004-awg31-central-contract](adr/ADR-004-awg31-central-contract.md) | Contract between the edge fleet and the central orchestrator for AmneziaWG 3.1 parameters. |
| [architecture/caddy-admin-api-mapping](architecture/caddy-admin-api-mapping.md) | How each tenants.yaml route action maps to Caddy admin-API JSON used by opec. |
| [relay-only-node](relay-only-node.md) | The TURN-only node profile: what it runs, what it never holds, how it is installed. |
| [relay-x-normalization](relay-x-normalization.md) | Plan to normalise the hybrid manually-managed relay topology. |
| [runbooks/ch3-retired](runbooks/ch3-retired.md) | Why the CH3 fallback channel was retired and what that means for nodes. |
| [runbooks/channels-health](runbooks/channels-health.md) | Runbook for the channels health report. |
| [runbooks/conf-d](runbooks/conf-d.md) | How operator Caddy fragments in conf.d are loaded after the generated Caddyfile. |
| [runbooks/m4a5-deploy](runbooks/m4a5-deploy.md) | Deploy notes for the browser-facing SFU WebSocket endpoint and its public-IP override. |
| [runbooks/multi-channel-deployment](runbooks/multi-channel-deployment.md) | Runbook for deploying the multi-channel tunnel setup. |
| [runbooks/opec-tenant](runbooks/opec-tenant.md) | Managing tenants.yaml and reconciling it with Caddy through opec. |
| [sfu-m2-renegotiation](sfu-m2-renegotiation.md) | Fix and design notes for SDP renegotiation in group SFU calls. |
| [CLAUDE](../CLAUDE.md) | Layout, the CI and local gate, and invariants for coding agents. |
