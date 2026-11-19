# 🚀 VOIDCORE VPN

**A smarter, simpler, and more powerful VPN experience.**

Welcome to VOIDCORE VPN! This release introduces powerful improvements to connection management, Cloudflare scanning, DNS functionality, routing, and privacy tools.

Our goal is to make advanced networking features easier to configure and use through a cleaner and more approachable experience.

---

## ☁️ Cloudflare Scanner

The Cloudflare scanning system now supports all protocols with improved configuration compatibility.

**Supported settings include:**
- Fingerprint and SNI
- IPv4 and IPv6
- Custom domains
- Transport configurations
- Fragment and UDP Obfuscation
- Configurable probe counts

*Note: Higher probe counts can improve scanning results but may consume more Cloudflare Worker requests during VLESS scanning. ECH is not included in scanner support.*

## 🌐 Serverless DNS

A new DNS mode brings traffic splitting and DNS testing into one integrated experience.

**Supported DNS protocols:**
- UDP
- TCP
- DNS over HTTPS (DoH)
- DNS over QUIC (DoQ)

Additional features:
- Cloudflare Workers and Pages private DoH endpoints
- Public DNS server options
- Built-in DNS testing
- Fake SNI support using Cloudflare, Google, and Quad9 DoH endpoints

## 🛡️ Privacy & Connection Improvements

- Added Snowflake AMP support to Tor modes.
- Added new Routing Strategy options.
- Improved connection-state verification before updating the interface.
- Updated Domain Fronting and Psiphon configurations.
- Changed default WARP Reserved Bytes behavior to disabled.
- Added a Prefer IPv6 option.
- Added ECH retries for Cloudflare API requests.

## ⚙️ Networking & UDP Enhancements

- Renamed Serverless Fragment to **Serverless Packet**.
- Updated default UDP Obfuscation noise presets.
- Added QUIC, DNS Query, and STUN Binding presets.
- Added a None mode for custom packet expressions.
- Updated Fragment default configuration.

## 🔧 Core & Routing Updates

- Updated Xray-core to v26.11.9.
- Updated Tor to v4.9.16.
- Updated routing rules.
- Added default blocking rules for Iran firewall IPs.
- Improved routing configuration.

## ⚠️ Important: After Updating

Some default settings have changed since versions 1.0.0 and 1.1.0.

We recommend resetting your settings after updating to ensure the new defaults are applied correctly.

**Your clean IPs and endpoints will be preserved.**

---

## 📥 Download VOIDCORE VPN

Choose the APK that matches your Android device architecture from the Assets section below.

**Available builds:**
- ARM64
- ARMv7
- x86_64
- Universal APK

*Always verify the downloaded APK and its SHA-256 checksum before installation.*

---

**VOIDCORE VPN**  
*Privacy. Connectivity. Control.*
