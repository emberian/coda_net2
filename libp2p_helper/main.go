package main

import (
	"bufio"
	"codanet"
	"context"
	"crypto/rand"
	"encoding/json"
	"github.com/go-errors/errors"
	logging "github.com/ipfs/go-log"
	logwriter "github.com/ipfs/go-log/writer"
	crypto "github.com/libp2p/go-libp2p-crypto"
	peer "github.com/libp2p/go-libp2p-peer"
	pubsub "github.com/libp2p/go-libp2p-pubsub"
	b58 "github.com/mr-tron/base58/base58"
	"github.com/multiformats/go-multiaddr"
	logging2 "github.com/whyrusleeping/go-logging"
	"log"
	"os"
	"sync"
	"time"
)

type subscription struct {
	Sub    *pubsub.Subscription
	Idx    int
	Ctx    context.Context
	Cancel context.CancelFunc
}

type app struct {
	// whatever your application state is
	P2p        *codanet.Helper
	Ctx        context.Context
	Subs       map[int]subscription
	Validators map[int]chan bool
	OutLock    sync.Mutex
	Out        *bufio.Writer
}

var seqs = make(chan int)

//go:generate jsonenums -type=methodIdx
type methodIdx int

const (
	configure methodIdx = iota
	listen
	publish
	subscribe
	unsubscribe
	registerValidator
	validationComplete
	generateKeypair
	closePipe
	sendPipe
)

type envelope struct {
	Method methodIdx   `json:"method"`
	Seqno  int         `json:"seqno"`
	Body   interface{} `json:"body"`
}

func (app *app) writeMsg(msg interface{}) {
	app.OutLock.Lock()
	defer app.OutLock.Unlock()
	bytes, err := json.Marshal(msg)
	if err == nil {
		n, err := app.Out.Write(bytes)
		if err != nil {
			panic(err)
		}
		if n != len(bytes) {
			panic("short write :(")
		}
		app.Out.WriteByte(0x0a)
		if err := app.Out.Flush(); err != nil {
			panic(err)
		}
	} else {
		panic(err)
	}
}

type action interface {
	run(app *app) (interface{}, error)
}

type configureMsg struct {
	Statedir  string   `json:"statedir"`
	Privk     string   `json:"privk"`
	NetworkID string   `json:"network_id"`
	ListenOn  []string `json:"ifaces"`
}

func (m *configureMsg) run(app *app) (interface{}, error) {
	privkBytes, err := b58.Decode(m.Privk)
	if err != nil {
		return nil, err
	}
	privk, err := crypto.UnmarshalPrivateKey(privkBytes)
	if err != nil {
		return nil, err
	}
	maddrs := make([]multiaddr.Multiaddr, len(m.ListenOn))
	for i, v := range m.ListenOn {
		res, err := multiaddr.NewMultiaddr(v)
		if err != nil {
			return nil, err
		}
		maddrs[i] = res
	}
	helper, err := codanet.MakeHelper(app.Ctx, maddrs, m.Statedir, privk, m.NetworkID)
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
		return nil, err
	}
	if err := app.P2p.Host.Network().Listen(ma); err != nil {
		return nil, err
	}
	return app.P2p.Host.Addrs(), nil
}

type publishMsg struct {
	Topic string `json:"topic"`
	Data  string `json:"data"`
}

func (t *publishMsg) run(app *app) (interface{}, error) {
	data, err := b58.Decode(t.Data)
	if err != nil {
		return nil, err
	}
	if err := app.P2p.Pubsub.Publish(t.Topic, data); err != nil {
		return nil, err
	}
	return "publish success", nil
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
				app.writeMsg(publishUpcall{
					Upcall:       "publish",
					Subscription: s.Subscription,
					Data:         data,
				})
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
	Idx    int    `json:"validator_idx"`
	Topic  string `json:"topic"`
}

type validationCompleteMsg struct {
	Seqno int  `json:"seqno"`
	Valid bool `json:"is_valid"`
}

type recvPipeMessageUpcall struct {
	Upcall  string `json:"upcall"`
	PipeIdx int    `json:"pipe_idx"`
	Data    string `json:"data"`
}

type pipeClosedUpcall struct {
	Upcall  string `json:"upcall"`
	PipeIdx int    `json:"pipe_idx"`
}

type sendPipeMessageMsg struct {
	PipeIdx int    `json:"pipe_idx"`
	Data    string `json:"data"`
}

type closePipeMsg struct {
	PipeIdx int `json:"pipe_idx"`
}

type newConnectionUpcall struct {
	Upcall      string `json:"upcall"`
	IncomingIdx int    `json:"incoming_idx"`
}

type acceptConn struct {
}

func (r *registerValidatorMsg) run(app *app) (interface{}, error) {
	ch := make(chan bool)

	seq := <-seqs
	app.Validators[seq] = ch

	err := app.P2p.Pubsub.RegisterTopicValidator(r.Topic, func(ctx context.Context, id peer.ID, msg *pubsub.Message) bool {
		app.writeMsg(validateUpcall{
			PeerID: id.Pretty(),
			Data:   b58.Encode(msg.Data),
			Seqno:  seq,
			Upcall: "validate",
			Idx:    r.Idx,
			Topic:  r.Topic,
		})

		return <-ch
	}, pubsub.WithValidatorConcurrency(1), pubsub.WithValidatorTimeout(5*time.Second))

	if err != nil {
		return nil, err
	}
	return "register validator success", nil
}

func (r *validationCompleteMsg) run(app *app) (interface{}, error) {
	if ch, ok := app.Validators[r.Seqno]; ok {
		ch <- r.Valid
		delete(app.Validators, r.Seqno)
		return "validation completed", nil
	}
	return nil, errors.New("validation seqno unknown")
}

type generateKeypairMsg struct {
}

type generatedKeypair struct {
	Private string `json:"privk"`
	Public  string `json:"pubk"`
}

func (*generateKeypairMsg) run(app *app) (interface{}, error) {
	privk, pubk, err := crypto.GenerateEd25519Key(rand.Reader)
	if err != nil {
		return nil, err
	}
	privkBytes, err := crypto.MarshalPrivateKey(privk)
	if err != nil {
		return nil, err
	}

	pubkBytes, err := crypto.MarshalPublicKey(pubk)
	if err != nil {
		return nil, err
	}

	return generatedKeypair{Private: b58.Encode(privkBytes), Public: b58.Encode(pubkBytes)}, nil
}

var msgHandlers = map[methodIdx]func() action{
	configure:          func() action { return &configureMsg{} },
	listen:             func() action { return &listenMsg{} },
	publish:            func() action { return &publishMsg{} },
	subscribe:          func() action { return &subscribeMsg{} },
	unsubscribe:        func() action { return &unsubscribeMsg{} },
	registerValidator:  func() action { return &registerValidatorMsg{} },
	validationComplete: func() action { return &validationCompleteMsg{} },
	generateKeypair:    func() action { return &generateKeypairMsg{} },
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
	logging.SetAllLoggers(logging2.INFO)

	go func() {
		i := 0
		for {
			seqs <- i
			i++
		}
	}()

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
			if err == nil {
				res, err := json.Marshal(res)
				if err == nil {
					app.writeMsg(successResult{Seqno: env.Seqno, Success: res})
				} else {
					app.writeMsg(errorResult{Seqno: env.Seqno, Errorr: err.Error()})
				}
			} else {
				app.writeMsg(errorResult{Seqno: env.Seqno, Errorr: err.Error()})
			}
		}()
	}
	log.Fatal("stdin eof, I guess we are done: ", lines.Err())
}

var _ json.Marshaler = (*methodIdx)(nil)
