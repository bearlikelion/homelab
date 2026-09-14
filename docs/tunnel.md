# GCP tunnel

Penpot and Foundry are public without exposing the home IP.
The GCP node in `../mark-gcp` (`seer`) terminates the public side, and a WireGuard tunnel carries the traffic to Caddy on `edge`:

    client -> Cloudflare (proxied) -> seer: Traefik :443, Let's Encrypt cert
           -> wg0 10.99.0.1 ==WireGuard==> edge wg0 10.99.0.2
           -> Caddy *.arneman.me -> design (192.168.1.230:9001), foundry (192.168.1.240:30000)

Nothing on seer forwards or routes into the LAN.
Traefik opens HTTPS to `10.99.0.2` with the service's name as SNI, and Caddy picks the upstream by Host exactly as it would for a LAN client.

## Who can reach what

- Seer listens on UDP 51820, open to the internet in GCP. WireGuard drops any packet not signed by a known key, and the home IP is dynamic.
- Edge dials out and keeps the tunnel alive, so nothing is forwarded on the home router.
- On edge, `wg0` accepts only TCP 443. The rule is in the mangle table so it matches before Docker's DNAT, which would otherwise expose AdGuard and Homepage.
- On seer, `wg0` accepts only replies to connections seer opened, so a compromised edge cannot reach the host or any pod.
- Caddy serves the tunneled names only to `10.99.0.1` and `192.168.1.0/24`. The same names arriving on the home IP are aborted.

## One-time host setup

An unprivileged container can create a WireGuard interface but cannot load the kernel module.
Run this once on the Proxmox host:

    echo wireguard > /etc/modules-load.d/wireguard.conf && modprobe wireguard

If `wg-quick@wg0` still fails inside `edge`, pass `/dev/net/tun` through as `vpn` and `darkfall` do and use `wireguard-go` instead.

## Keys

Each side's private key is `wireguard_private_key` in its own repo's `secrets.sops.yml`.
The other side's public key sits in plain group_vars: `seer_wireguard_public_key` here, `wireguard_peer_public_key` in mark-gcp.

To rotate, generate a pair without needing `wg` installed:

    openssl genpkey -algorithm X25519 -outform DER -out k.der
    tail -c 32 k.der | base64                                           # private
    openssl pkey -inform DER -in k.der -pubout -outform DER | tail -c 32 | base64   # public
    rm k.der

Then update both repos and deploy both sides.

## Publishing another service

The name has to be added in three places, and they must agree:

1. `tunneled_services` in `ansible/group_vars/all/main.yml` here, then `make deploy`.
2. `homelab_services` in mark-gcp's `ansible/group_vars/all/main.yml`, then `ansible-playbook site.yml --tags homelab` there.
3. `homelab_hosts` in mark-gcp's `live/prod/network`, then apply that layer to create the DNS record.

The app must also be told its public URL (Penpot's `penpot_public_uri`, Foundry's `FOUNDRY_HOSTNAME`), or links and websockets point at the wrong host.

## Checks

    # on seer
    sudo wg show                                  # recent handshake with edge
    curl -sI --resolve design.arneman.me:443:10.99.0.2 https://design.arneman.me
    sudo k3s kubectl get certificate,ingressroute -n homelab

    # on edge
    wg show

If both apps return 502 from Traefik, the tunnel is down: check `systemctl status wg-quick@wg0` on both ends.

## Limits

- Cloudflare's free plan caps request bodies at 100 MB.
  For larger uploads, point the name at `192.168.1.130` with an AdGuard rewrite or a hosts entry; Caddy accepts LAN clients directly, so the request never touches Cloudflare.
- Responses leave GCP as Standard tier egress, free up to 200 GiB a month.
- Seer holds a Cloudflare token that can edit arneman.me DNS, because cert-manager needs it for DNS-01.
