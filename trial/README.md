# IPChakra — Trial Setup (Residential rotating IP test)

Naam pakka: **IPChakra** ✅ (verified: is naam se koi VPN app exist nahi karti)

## Trial ka flow

```
Tumhara phone --(WireGuard)--> Tumhara VPS --(redsocks+iptables)--> Residential proxy pool --> Internet
```

Phone pe official **WireGuard** app use hogi (IPChakra app trial ke baad banegi).
Bahar wali duniya ko **residential IP** dikhega, aur har reconnect/interval pe IP **badlega**.

## Tumhara kaam (30 min)

1. **DataImpulse** (dataimpulse.com) pe signup → $5 top-up → residential proxy credentials banao.
   Note kar lo: `host`, `port`, `username`, `password`.
2. **Evomi** (evomi.com) pe free trial signup → trial credentials banao (host/port/user/pass).
3. Dono credentials **Secure Vault** me dena — link main dunga jab bologe. Chat me password kabhi mat bhejna.
4. Ek **VPS** le lo: Ubuntu 22.04/24.04, 1GB RAM, Mumbai ya Singapore region
   (₹179–500/month wale options research me nikale the). Ispe root SSH chahiye.

## Mera kaam (credentials + VPS milte hi)

1. `01-server-setup.sh` VPS pe chalana (tum khud bhi chala sakte ho — upar PROXY_* bhar ke `sudo bash 01-server-setup.sh`).
   Ye banayega: WireGuard server + redsocks (TCP → residential pool) + iptables rules.
2. Script ke end me `/root/ipchakra-trial-client.conf` milegi — ise phone ki WireGuard app me import karo.
3. `test-rotation.sh` se verify karo: 5 baar alag-alag residential IP + speed test.

## Kya verify karna hai (trial success criteria)

- [ ] 5 tries me 4–5 **alag** exit IPs aaye (rotation kaam kar raha)
- [ ] Exit IP **residential** dikhe (datacenter nahi) — `ipinfo.io/<ip>` pe check karna
- [ ] Speed: ghar ke fiber jaisi nahi hogi, par browsing ke layak (5–30 Mbps typical)
- [ ] DataImpulse vs Evomi — jo stable + tez lage, wahi final

## Trial limitations (pehle se pata ho)

- **TCP hi residential se jayega** (browsing, apps ka zyadatar traffic). UDP trial me seedha VPS se niklega.
  Final app me iska proper solution hoga.
- Per-GB cost hai — trial me 5 GB hai, video streaming mat karna 😄
- Ye trial **server-side** hai; IPChakra Flutter app iske baad banegi, jisme 2 modes honge:
  - **Free Mode** — apna VPS, datacenter IP, unlimited, sabse tez
  - **Chakra Mode** — rotating residential/mobile IP (paid pool)

## Files

| File | Kaam |
|---|---|
| `01-server-setup.sh` | VPS pe poora chain setup (WireGuard + redsocks + iptables) |
| `test-rotation.sh` | IP rotation + speed verify |
| `README.md` | Ye file |

Jab credentials + VPS ready ho, bas "trial shuru karo" bol dena.
