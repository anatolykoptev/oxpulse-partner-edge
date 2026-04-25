# Hysteria2 client configuration (CH3 fallback channel).
# Activated when the operator's backend returns CH3 config in channels[].
# Server uses salamander obfuscation; traffic appears as random UDP noise.
server: "{{HYSTERIA2_SERVER}}:{{HYSTERIA2_PORT}}"

auth: "{{HYSTERIA2_AUTH}}"

tls:
  insecure: true

obfs:
  type: salamander
  salamander:
    password: "{{HYSTERIA2_OBFS}}"

socks5:
  listen: "127.0.0.1:{{HYSTERIA2_SOCKS_PORT}}"

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
