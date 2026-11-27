# shelly-mqtt

Shelly H&T Gen3 (USB powered, wakes every 5 minutes) -> Mosquitto (mTLS, `192.168.1.241:8883`) -> mqtt2prometheus -> Prometheus.
The device sleeps with Wi-Fi off between wakes, so it cannot be scraped; it pushes.

- Network: the Shelly is on the UniFi `IoT` network (VLAN 30, 192.168.7.0/24, Isolate Network on). A policy `IoT to MQTT broker`
  allows TCP 8883 to 192.168.1.241 only. The Cilium policy admits the same CIDR.
- Auth: client certificate, CN = MQTT username (`shelly-ht`, `mqtt2prometheus`); topics are limited in `acl`.
- Topics: one prefix per device, `shelly/ht-1` (H&T) and `shelly/pill-1` (Pill), status on `<prefix>/status/<component>:<id>`. Both share the `shelly-ht` client certificate; the ACL limits it to those two prefixes.

## Device setup (manual, once)

1. Export `ca.crt`, `tls.crt` and `tls.key` of Secret `mqtt-client-shelly-ht`. Keep the key out of chats, PRs and the repo.
2. Upload them to the Shelly while it is awake (reset button, or setup mode). Method names: see Shelly's "SSL support for outbound connections".
3. `Mqtt.SetConfig`: `enable: true`, `server: "192.168.1.241:8883"`, `ssl_ca: "user_ca.pem"`, `use_client_cert: true`,
   `status_ntf: true`, `topic_prefix: "shelly/ht-1"`.

The client certificate lasts 2 years and the device cannot renew it: repeat the upload before it expires.
