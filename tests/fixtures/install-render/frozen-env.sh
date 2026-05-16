# Frozen environment for Phase 1 install render golden tests.
# Values chosen to match a synthetic zvonilka-style node registration.
# Changes here require regenerating expected/*.txt via /tmp/freeze-install-render.sh.

export PARTNER_ID=zvonilka
export PARTNER_DOMAIN=zvonilka.net
export BACKEND_ENDPOINT=192.9.243.148:5349
export BACKEND_HOST=192.9.243.148
export BACKEND_PORT=5349
export TURN_SECRET=test-turn-secret-deadbeef
export REALITY_UUID=d529dee6-3cdd-4079-95d1-f8801722147c
export REALITY_PUBLIC_KEY=U6ea044JJjgiCjQAnYEBqBBlkeSqrQaLq3lcjnN2EFk
export REALITY_SHORT_ID=abcd1234
export REALITY_SERVER_NAME=www.samsung.com
export REALITY_ENCRYPTION=mlkem768x25519plus.native.0rtt.fXgOoxcW
export TURNS_SUBDOMAIN=api-test01
export PUBLIC_IP=157.22.204.190
export PRIVATE_IP=
export EXTERNAL_IP_LINE=157.22.204.190
export IMAGE_VERSION=stable
export SFU_UDP_PORT=7878
export SFU_METRICS_PORT=9317
export SFU_EDGE_ID=zvonilka1
export OTEL_EXPORTER_OTLP_ENDPOINT=
# install.sh:1380-1383 escapes real newlines to literal \n before render —
# fixture uses literal-\n form to match install.sh behaviour.
export SFU_SIGNING_PUBLIC_KEY='-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAZiwaWp+FJ1sGprGGS69mq+sB6nhwOMi24xGSGfgdXNo=\n-----END PUBLIC KEY-----\n'
export RELAY_JWT_SECRET=test-relay-jwt-secret
export SIGNALING_SFU_SECRET=test-signaling-sfu-secret
export HYSTERIA2_SERVER=
export HYSTERIA2_PORT=51822
export HYSTERIA2_AUTH=
export HYSTERIA2_OBFS=
export HYSTERIA2_SOCKS_PORT=18891
export NAIVE_SERVER=
export NAIVE_PORT=44433
export NAIVE_USER=
export NAIVE_PASS=
export NAIVE_SOCKS_PORT=18892
