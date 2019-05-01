package main

import (
	"bufio"
	"codanet"
	"context"
	"crypto/rand"
	"encoding/hex"
	logging "github.com/ipfs/go-log"
	logwriter "github.com/ipfs/go-log/writer"
	crypto "github.com/libp2p/go-libp2p-crypto"
	"log"
	"os"
)

func main() {
	logwriter.Configure(logwriter.Output(os.Stderr))
	log.SetOutput(os.Stderr)
	logging.SetDebugLogging()

	ctx := context.Background()
	privk, pubk, err := crypto.GenerateEd25519Key(rand.Reader)

	if err != nil {
		log.Fatalf("failed to generate keypair: %s", err)
	}

	mpub, err := crypto.MarshalPublicKey(pubk)
	if err != nil {
		log.Fatalf("failed to marshal pub: %v", err)
	}
	mpriv, err := crypto.MarshalPrivateKey(privk)
	if err != nil {
		log.Fatalf("failed to marshal priv: %v", err)
	}
	log.Printf("pub: %s priv: %s", hex.EncodeToString(mpub), hex.EncodeToString(mpriv))

	helper, err := codanet.MakeHelper(ctx, "/tmp/libp2p-state", privk, []byte("foobar"))

	if err != nil {
		log.Fatalf("failed to make helper: %v", err)
	}

	addrs, err := helper.Host.Network().InterfaceListenAddresses()

	for _, maddr := range addrs {
		log.Printf("a listening addr: %s", maddr.String())
	}

	lines := bufio.NewScanner(os.Stdout)

	for lines.Scan() {
		line := lines.Text()
		helper.Handle(line)
	}
	log.Fatal("stdin eof, I guess we are done: ", lines.Err())
}
