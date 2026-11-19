#!/usr/bin/env bash
# Generates the CA and JWT key pools of Agent Substrate (k8s/apps/ate-system-secrets/*.enc.yaml), SOPS-encrypted with the age recipient of
# .sops.yaml. Substrate writes these pools in its own format (internal/localca, internal/localjwtauthority), so cert-manager and the
# External Secrets generators cannot make them; this builds the same Secrets as `ate-setup deploy ate-system` would, from the pinned
# release. A Secret that already has a file is left alone, as ate-setup leaves an existing pool: regenerating a CA invalidates every
# certificate issued from it. The CAs are valid for a year: delete the files and run this again to rotate them (see README.md).
#
# Needs: git, go (1.27 or newer), sops. Run it on a machine you trust, from anywhere in a clone; then commit the files it wrote.
set -euo pipefail

TAG="v1.0.0" # keep in step with the images in k8s/apps/ate-system/rendered/
repo="$(git rev-parse --show-toplevel)"
out="${repo}/k8s/apps/ate-system-secrets"
mkdir -p "${out}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
git clone --quiet --depth 1 --branch "${TAG}" https://github.com/agent-substrate/substrate.git "${work}/substrate"
mkdir "${work}/substrate/cmd/ate-gen-secrets"
cat >"${work}/substrate/cmd/ate-gen-secrets/main.go" <<'GO'
// Writes the Secrets that cmd/ate-setup/internal/steps/create.go creates, as manifests with base64 data, into the directory in os.Args[1].
package main

import (
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"

	"go.ate.dev/substrate/internal/localca"
	"go.ate.dev/substrate/internal/localjwtauthority"
)

const (
	poolKeyID  = "1"
	caValidity = 365 * 24 * time.Hour
)

func must[T any](v T, err error) T {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	return v
}

func write(dir, namespace, name, secretType string, data map[string][]byte) {
	path := filepath.Join(dir, name+".enc.yaml")
	if _, err := os.Stat(path); err == nil {
		fmt.Printf("%s exists; keeping it\n", path)
		return
	}
	keys := make([]string, 0, len(data))
	for k := range data {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	s := fmt.Sprintf("apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: %s\ndata:\n", name, namespace, secretType)
	for _, k := range keys {
		s += fmt.Sprintf("  %s: %s\n", k, base64.StdEncoding.EncodeToString(data[k]))
	}
	if err := os.WriteFile(path, []byte(s), 0o600); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("wrote %s\n", path)
}

// caPool is newCAPoolSecretData: the marshaled pool, plus the root chain and key under the standard TLS keys.
func caPool(keyType localca.KeyType) (map[string][]byte, *localca.CA) {
	ca := must(localca.GenerateCA(poolKeyID, keyType, caValidity))
	pool := must(localca.Marshal(&localca.ConcretePool{CAs: []*localca.CA{ca}, ActiveForSigning: poolKeyID}))
	return map[string][]byte{
		"pool":    pool,
		"tls.crt": must(ca.TLSCertificateChainPEM()),
		"tls.key": must(ca.TLSPrivateKeyPEM()),
	}, ca
}

func main() {
	dir := os.Args[1]
	const tls, opaque = "kubernetes.io/tls", "Opaque"

	pool, _, err := localjwtauthority.GeneratePool("ES256", "")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	write(dir, "ate-system", "actor-id-jwt-pool", opaque, map[string][]byte{"pool": pool})

	actorCA, ca := caPool(localca.KeyTypeECDSAP256)
	write(dir, "ate-system", "actor-id-ca-pool", tls, actorCA)
	root := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: ca.RootCertificate.Raw})
	write(dir, "ate-system", "actor-id-ca-certs", opaque, map[string][]byte{"ca.crt": root})

	mitm, _ := caPool(localca.KeyTypeECDSAP256)
	write(dir, "ate-system", "egress-mitm-ca-pool", tls, mitm)

	for _, name := range []string{"service-dns-ca-pool", "pod-identity-ca-pool", "postgres-ca-pool"} {
		data, _ := caPool(localca.KeyTypeED25519)
		write(dir, "podcertificate-controller-system", name, tls, data)
	}
}
GO

(cd "${work}/substrate" && go run ./cmd/ate-gen-secrets "${out}")

for f in "${out}"/*.enc.yaml; do
  # an already encrypted file (kept above) carries a sops block
  grep -q '^sops:' "${f}" || sops --encrypt --in-place "${f}"
done
echo "Done. Review with git status, commit k8s/apps/ate-system-secrets/, and never commit a file without a sops: block."
