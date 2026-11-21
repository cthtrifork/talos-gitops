# net-test (temporary)

A pod network throughput test: an iperf3 server and two client Jobs, one on another node than the server and one on the same
node. It answers why a transfer between pods on two nodes stalls (a 190 MB cache upload from a runner to the cache server stopped
after a few MB while the same upload on one node took seconds), without exec access to the nodes.

Read the results with `kubectl -n net-test-system logs job/iperf-client-cross-node` and `...same-node` (the same-node Job waits 7 minutes so
the two do not share the server). The runs compare the default congestion control (the cluster runs BBR on the pods), CUBIC and BBR, the
default and a small segment size (a path MTU blackhole stalls only with the large one), parallel streams, and UDP, each way.

Delete the app (the line in `k8s/clusters/homelab/kustomization.yaml`, the `app-net-test.yaml` file and this directory) when done: Flux prunes it.
