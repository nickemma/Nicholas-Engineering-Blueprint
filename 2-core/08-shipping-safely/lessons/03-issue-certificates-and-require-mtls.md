# 03 Issue certificates and require mTLS

## The problem

The client needs to verify the server it calls. The server needs to verify the calling client and read a signed identity. A role string supplied in a request is under the caller's control.

## The pattern

The private CA signs leaf certificates for different purposes. The gateway leaf is valid for server authentication and contains an IP subject alternative name. The reader and writer leaves are valid for client authentication and each contains one URI subject alternative name. The gateway asks Go TLS for a verified client chain before HTTP is reachable. The client verifies the gateway against the lab CA and hostname or IP. Use separate restricted key files. The CA signing key is used only during issuance.

## Build it

### Step 1. Generate a temporary lab CA and short-lived leaf certificates

Type the script. Fill in the leaf extended key usages and names before running it.

<details>
<summary>Hint</summary>

The client role is encoded in the URI SAN. Match the loopback IP separately on the gateway leaf.

</details>

<details>
<summary>Completed files</summary>

Create `ops/pki.sh`.

<!-- file: ops/pki.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
umask 077
pki=$1
mkdir -m 700 "$pki"
cd "$pki"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc -sha256 \
  -days 2 -subj '/CN=Switchyard lab CA' \
  -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' -keyout ca.key -out ca.crt
issue() {
  local name=$1 purpose=$2 san=$3
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc \
    -subj "/CN=$name" -keyout "$name.key" -out "$name.csr"
  printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=%s\nsubjectAltName=%s\n' \
    "$purpose" "$san" > "$name.ext"
  openssl x509 -req -in "$name.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days 1 -sha256 -extfile "$name.ext" -out "$name.crt"
  rm -- "$name.csr" "$name.ext"
}
issue gateway serverAuth IP:127.0.0.1
issue reader clientAuth URI:urn:switchyard:reader
issue writer clientAuth URI:urn:switchyard:writer
~~~

</details>
### Step 2. Require verified clients

Implement both TLS configurations. Keep explicit trust roots for the client and server. Load the private key through its existing descriptor and check file permissions before reading.

<details>
<summary>Hint</summary>

Set RequireAndVerifyClientCert on the server. The ordinary client verifier still needs RootCAs and the server name from the URL.

</details>

<details>
<summary>Completed files</summary>

Create `internal/edge/config.go`.

<!-- file: internal/edge/config.go -->
~~~go
package edge

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"os"
	"path/filepath"
)

func roots(path string) (*x509.CertPool, error) {
	pem, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, errors.New("invalid CA PEM")
	}
	return pool, nil
}

func loadPair(cert, key string) (tls.Certificate, error) {
	file, err := os.Open(key)
	if err != nil {
		return tls.Certificate{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return tls.Certificate{}, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 64<<10 {
		return tls.Certificate{}, errors.New("private key requires a small, owner-restricted regular file")
	}
	pem, err := io.ReadAll(io.LimitReader(file, (64<<10)+1))
	if err != nil {
		return tls.Certificate{}, err
	}
	if len(pem) > 64<<10 {
		return tls.Certificate{}, errors.New("private key file grew while reading")
	}
	certPEM, err := os.ReadFile(cert)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.X509KeyPair(certPEM, pem)
}

func TLSConfig(ca, cert, key string, server bool) (*tls.Config, error) {
	pool, err := roots(ca)
	if err != nil {
		return nil, err
	}
	pair, err := loadPair(cert, key)
	if err != nil {
		return nil, err
	}
	cfg := &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{pair}}
	if server {
		cfg.ClientCAs = pool
		cfg.ClientAuth = tls.RequireAndVerifyClientCert
	} else {
		cfg.RootCAs = pool
	}
	return cfg, nil
}

func CheckSocketPath(path string) error {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return errors.New("upstream socket path must be absolute and clean")
	}
	info, err := os.Lstat(filepath.Dir(path))
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return errors.New("upstream socket requires a private directory")
	}
	return nil
}
~~~

</details>

## Check it

~~~bash
(lab=$(mktemp -d) && trap 'rm -rf -- "$lab"' EXIT && bash ops/pki.sh "$lab/certs" && cd "$lab/certs" && openssl verify -CAfile ca.crt -purpose sslserver gateway.crt && openssl verify -CAfile ca.crt -purpose sslclient reader.crt writer.crt)
~~~

<!-- run: (lab=$(mktemp -d) && trap 'rm -rf -- "$lab"' EXIT && bash ops/pki.sh "$lab/certs" && cd "$lab/certs" && openssl verify -CAfile ca.crt -purpose sslserver gateway.crt && openssl verify -CAfile ca.crt -purpose sslclient reader.crt writer.crt) -->

~~~text
gateway.crt: OK
reader.crt: OK
writer.crt: OK
~~~

The output checks issuance and certificate purpose. The live gate verifies that missing or untrusted credentials cannot reach HTTP.

[Captured output](../evidence/03-pki.txt)

## Explain it

Why does signing a client certificate grant identity while the gateway still needs an operation policy?
