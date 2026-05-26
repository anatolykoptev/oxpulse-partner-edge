#!/usr/bin/env bats
# tests/test_channels_health_central_url.sh — the channel-health reporter must
# target the central API host (api.oxpulse.chat), NOT the public oxpulse.chat.
# RCA 2026-05-26: reporter defaulted to oxpulse.chat, which geo-resolves to the
# edge's OWN IP -> TLS loopback -> HTTP 000 -> all 5 edges' last_seen 29.5h stale.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMP="$(mktemp -d)"
	SYSTEMD_DIR="$TMP/systemd"
	mkdir -p "$SYSTEMD_DIR"
	# shellcheck disable=SC1090
	source "$REPO_ROOT/lib/install-systemd.sh"
}
teardown() { rm -rf "$TMP"; }

@test "drop-in renders OXPULSE_BACKEND_API from BACKEND_API (prod default api.oxpulse.chat)" {
	BACKEND_API="https://api.oxpulse.chat"
	_systemd_render_channel_health_dropin
	conf="$SYSTEMD_DIR/oxpulse-channels-health-report.service.d/10-central-url.conf"
	[ -f "$conf" ]
	grep -qx "Environment=OXPULSE_BACKEND_API=https://api.oxpulse.chat" "$conf"
}

@test "drop-in honors a staging BACKEND_API override" {
	BACKEND_API="https://staging.oxpulse.chat"
	_systemd_render_channel_health_dropin
	grep -qx "Environment=OXPULSE_BACKEND_API=https://staging.oxpulse.chat" \
		"$SYSTEMD_DIR/oxpulse-channels-health-report.service.d/10-central-url.conf"
}

@test "reporter script standalone default is api.oxpulse.chat, not edge-looping oxpulse.chat" {
	line="$(grep -E '^OXPULSE_BACKEND_API=' "$REPO_ROOT/oxpulse-channels-health-report.sh" | head -1)"
	[[ "$line" == *"api.oxpulse.chat"* ]]
	[[ "$line" != *":-https://oxpulse.chat}"* ]]
}
