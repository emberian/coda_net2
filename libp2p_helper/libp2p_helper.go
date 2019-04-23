package codanet

import (
	"context"

	libp2p "github.com/libp2p/go-libp2p"
	host "github.com/libp2p/go-libp2p-host"
)

// Helper contains all the daemon state
type Helper struct {
	host host.Host
	ctx  context.Context
}

func makeHost(ctx context.Context) (host.Host, error) {
	libp2p.NewWithoutDefaults(ctx)
}

func main() {
	host, err := makeHost()
}
