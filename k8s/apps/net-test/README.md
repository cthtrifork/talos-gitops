# net-test (temporary)

A pod network throughput test: one iperf3 server per node and one client Job per node, every client testing every server (so every
node pair both ways, and each node against itself as the baseline). It answers why a transfer between pods on two nodes stalls (a
190 MB cache upload from a runner on talos-11a-esj to the cache server on talos-tba-msi stopped after a few MB while the same upload on one node took
seconds) and whether a node is the cause (talos-2ny-8tx is the Proxmox VM; the test pods tolerate its control plane taint), without exec
access to the nodes.

Read the results with `kubectl -n net-test-system logs job/iperf-client-<node>`; the Jobs start 5 minutes apart so no two clients share a
server. The runs compare the default congestion control (the cluster runs BBR on the pods), CUBIC and BBR, and the default and a small
segment size (a path MTU blackhole stalls only with the large one), each way; the default test prints every second, so a stall shows as intervals at 0.

Delete the app (the line in `k8s/clusters/homelab/kustomization.yaml`, the `app-net-test.yaml` file and this directory) when done: Flux prunes it.
