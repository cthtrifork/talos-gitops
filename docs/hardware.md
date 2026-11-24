# Hardware overview

Which physical machine is which Kubernetes node. Regenerate the table with `scripts/node-inventory.sh` (read-only; needs `kubectl`, `talosctl` and `jq`).
Match a machine by the model and MAC on its sticker (NUCs: bottom label; Lenovo: case label), the MAC in your router's DHCP lease list, or the disk serial printed on the drive label.

Last captured 2026-11-24:

| Node | IP | CPU | Memory | Machine | NIC (MAC) | Disks | Label on machine |
|---|---|---|---|---|---|---|---|
| talos-11a-esj | 192.168.1.184 | 8 | 62 GiB | ASUS `NUC15CRHC3` | enp87s0 (88:ae:dd:68:01:ed) | nvme KINGSTON SNV3S1000G 1 TB (50026B76874D970E); nvme TS256GMTE400S 256 GB (J029620144); USB 4 TB | [ ] |
| talos-tba-msi | 192.168.1.146 | 4 | 15 GiB | Lenovo ThinkCentre M900x `10LYS00P00` | eno1 (00:23:24:c1:62:01) | nvme KINGSTON SNV2S1000G 1 TB (50026B738311F2C9); SATA SAMSUNG MZ7TY256 256 GB | [ ] |
| talos-vt2-qp8 | 192.168.1.112 | 2 | 31 GiB | Intel NUC `NUC11ATKC2` | eno1 (88:ae:dd:03:8b:cd) | nvme INTEL SSDPEKNW512G8 512 GB (PHNH21220250512A); USB 4 TB (Expansion HDD) | [ ] |
| talos-2jc-qux | 192.168.1.173 | 4 | 31 GiB | unknown (down when captured) | unknown | NVMe + SATA SSD | [ ] |

Tick the last column once the label is on the machine. What to write on it: node name, IP and short disk summary, for example `talos-2jc-qux / .173 / NVMe + SATA`.

`talos-2jc-qux` is the machine left over once the other three are identified. It is the only node with 4 cores and 31 GiB, and its MAC matches none of the three above. Fill in its MAC and serial here once it is back up.

## Finding the right machine when a node is down

1. Rule out the three running ones by model and by the MAC on the sticker (see the table above). The remaining machine is the dead node.
2. Check the router's DHCP lease list or ARP table for 192.168.1.173. A lease that is no longer renewed, or missing, points at the dead machine; the MAC there goes in the table.
3. If the stickers are not enough, look at the machines: the dead one has no network link light and shows a frozen or blank screen on a monitor. A healthy one has a link light that blinks, and Talos shows its hostname and IP on the console.
4. Put a label on each machine with its node name and tick the last column.
