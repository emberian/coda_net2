package main

import (
	"bufio"
	"codanet"
	"context"
	"encoding/json"
	"errors"
	logging "github.com/ipfs/go-log"
	logwriter "github.com/ipfs/go-log/writer"
	crypto "github.com/libp2p/go-libp2p-crypto"
	pubsub "github.com/libp2p/go-libp2p-pubsub"
	b58 "github.com/mr-tron/base58/base58"
	"github.com/multiformats/go-multiaddr"
	"log"
	"os"
)

type subscription struct {
	Sub    *pubsub.Subscription
	Idx    int
	Ctx    context.Context
	Cancel context.CancelFunc
}

type app struct {
	// whatever your application state is
	P2p  *codanet.Helper
	Ctx  context.Context
	Subs map[int]subscription
	Out  *bufio.Writer
}

//go:generate jsonenums -type=methodIdx

type methodIdx int

const (
	configure methodIdx = iota
	listen
	publish
	subscribe
	unsubscribe
	registerValidator
)

type envelope struct {
	Method methodIdx   `json:"method"`
	Seqno  int         `json:"seqno"`
	Body   interface{} `json:"body"`
}

func writeMsg(msg interface{}, wr *bufio.Writer) {
	bytes, err := json.Marshal(msg)
	if err != nil {
		n, err := wr.Write(bytes)
		if err != nil {
			panic(err)
		}
		if n != len(bytes) {
			panic("short write :(")
		}
	} else {
		panic(err)
	}
}

type action interface {
	run(app *app) (interface{}, error)
}

type configureMsg struct {
	Statedir  string `json:"statedir"`
	Privk     string `json:"privk"`
	NetworkID string `json:"network_id"`
}

func (m *configureMsg) run(app *app) (interface{}, error) {
	privkBytes, err := b58.Decode(m.Privk)
	if err != nil {
		return nil, err
	}
	privk, err := crypto.UnmarshalEd25519PrivateKey(privkBytes)
	if err != nil {
		return nil, err
	}
	helper, err := codanet.MakeHelper(app.Ctx, m.Statedir, privk, m.NetworkID)
	if err != nil {
		return nil, err
	}
	app.P2p = helper
	return "configure success", nil
}

type listenMsg struct {
	Iface string `json:"iface"`
}

func (m *listenMsg) run(app *app) (interface{}, error) {
	ma, err := multiaddr.NewMultiaddr(m.Iface)
	if err != nil {
		return "", err
	}
	app.P2p.Host.Network().Listen(ma)
	return "null", nil
}

type publishMsg struct {
	Topic string `json:"topic"`
	Data  string `json:"data"`
}

func (t *publishMsg) run(app *app) (interface{}, error) {
	return "publish success", app.P2p.Pubsub.Publish(t.Topic, []byte(t.Data))
}

type subscribeMsg struct {
	Topic        string `json:"topic"`
	Subscription int    `json:"subscription_idx"`
}

type publishUpcall struct {
	Upcall       string `json:"upcall"`
	Subscription int    `json:"subscription_idx"`
	Data         string `json:"data"`
}

func (s *subscribeMsg) run(app *app) (interface{}, error) {
	sub, err := app.P2p.Pubsub.Subscribe(s.Topic)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(app.Ctx)
	app.Subs[s.Subscription] = subscription{
		Sub:    sub,
		Idx:    s.Subscription,
		Ctx:    ctx,
		Cancel: cancel,
	}
	go func() {
		for {
			msg, err := sub.Next(ctx)
			if err == nil {
				data := b58.Encode(msg.Data)
				writeMsg(publishUpcall{
					Upcall:       "publish",
					Subscription: s.Subscription,
					Data:         data,
				}, app.Out)
			} else {
				if ctx.Err() != context.Canceled {
					log.Print("sub.Next failed: ", err)
				} else {
					break
				}
			}
		}
	}()
	return "subscribe success", nil
}

type unsubscribeMsg struct {
	Subscription int `json:"subscription_idx"`
}

func (u *unsubscribeMsg) run(app *app) (interface{}, error) {
	if sub, ok := app.Subs[u.Subscription]; ok {
		sub.Sub.Cancel()
		sub.Cancel()
		return "unsubscribe success", nil
	}
	return nil, errors.New("subscription not found")
}

type registerValidatorMsg struct {
	Topic string `json:"topic"`
	Idx   int    `json:"validator_idx"`
}

type validateUpcall struct {
	PeerID string `json:"peer_id"`
	Data   string `json:"data"`
	Seqno  int    `json:"seqno"`
	Upcall string `json:"upcall"`
	Topic  string `json:"topic"`
}

type validatedMsg struct {
	Seqno int  `json:"seqno"`
	Valid bool `json:"is_valid"`
}

func (r *registerValidatorMsg) run(app *app) (interface{}, error) {
	return nil, errors.New("register validator")
}

var msgHandlers = map[methodIdx]func() action{
	configure:         func() action { return &configureMsg{} },
	listen:            func() action { return &listenMsg{} },
	publish:           func() action { return &publishMsg{} },
	subscribe:         func() action { return &subscribeMsg{} },
	unsubscribe:       func() action { return &unsubscribeMsg{} },
	registerValidator: func() action { return &registerValidatorMsg{} },
}

type errorResult struct {
	Seqno  int    `json:"seqno"`
	Errorr string `json:"error"`
}

type successResult struct {
	Seqno   int             `json:"seqno"`
	Success json.RawMessage `json:"success"`
}

func main() {
	logwriter.Configure(logwriter.Output(os.Stderr))
	log.SetOutput(os.Stderr)
	logging.SetDebugLogging()

	lines := bufio.NewScanner(os.Stdin)
	out := bufio.NewWriter(os.Stdout)

	app := &app{
		P2p:  nil,
		Ctx:  context.Background(),
		Subs: make(map[int]subscription),
		Out:  out,
	}

	for lines.Scan() {
		line := lines.Text()
		go func() {
			// process an incoming message
			var raw json.RawMessage
			env := envelope{
				Body: &raw,
			}
			if err := json.Unmarshal([]byte(line), &env); err != nil {
				log.Fatal(err)
			}
			msg := msgHandlers[env.Method]()
			if err := json.Unmarshal(raw, msg); err != nil {
				log.Fatal(err)
			}
			res, err := msg.run(app)
			if err != nil {
				res, err := json.Marshal(res)
				if err != nil {
					writeMsg(successResult{Seqno: env.Seqno, Success: res}, out)
				} else {
					writeMsg(errorResult{Seqno: env.Seqno, Errorr: err.Error()}, out)
				}
			} else {
				writeMsg(errorResult{Seqno: env.Seqno, Errorr: err.Error()}, out)
			}
		}()
	}
	log.Fatal("stdin eof, I guess we are done: ", lines.Err())
}
