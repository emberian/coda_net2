open Core
open Async
open Async_unix
open Deferred.Or_error.Let_syntax

module Helper = struct
    type t = { subprocess: Process.t ; outstanding_requests: (int, Yojson.Safe.json Or_error.t Ivar.t) Hashtbl.t; seqno: int ref}

    let create () = 
        let%map subprocess = Process.create ~prog:"go" ~args:["run"; "libp2p_helpers/main.go"] () in
        let t = { subprocess; outstanding_requests= Hashtbl.create (module Int); seqno= ref 1} in
        let lines = Process.stdout subprocess |> Reader.lines in
        Pipe.iter lines ~f:(fun line -> 
            let open Yojson.Safe.Util in
            let v = Yojson.Safe.from_string line in
            let seq = v |> member "seqno" |> to_int in
            let err = v |> member "error" in
            let res = v |> member "result" in
            Hashtbl.change t.outstanding_requests seq ~f:(function
            | Some ivar ->
                (match (err, res) with
                | (`Null, r) ->
                    Ivar.fill ivar (Ok r)
                | (e, `Null) ->
                    Ivar.fill ivar (Or_error.error_string (sprintf "RPC #%d failed: %s" seq (Yojson.Safe.to_string e)))
                | (_, _) -> eprintf "neither an error nor a result :(\n%!");
                None
            | None -> eprintf "spurious reply to RPC #%d: %s\n%!" seq line; None) ;
            Deferred.unit
        ) 
        |> don't_wait_for ;
        t
    
    let genseq t = 
        let v = !(t.seqno) in
        incr t.seqno ;
        v

    let do_rpc t body = 
        let res = Ivar.create () in
        let seqno = genseq t in
        Hashtbl.add_exn t.outstanding_requests ~key:seqno ~data:res ;
        let actual_obj = `Assoc ["seqno", `Int seqno; "body", body] in
        let rpc = Yojson.Safe.to_string actual_obj in
        Writer.write (Process.stdin t.subprocess) rpc
end

type t =  {
    helper: Helper.t
}

type net_t = t

type peer_id = string

(* We hardcode support for only Ed25519 keys so we can keygen without calling go *)
module Keypair = struct
    open Callipyge

    type t = {secret: secret key; public: public key}
    
    (* BTC alphabet *)
    let alphabet = B58.make_alphabet "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

    let random () =
        let open Deferred.Let_syntax in
        let%bind urandom = Reader.open_file "/dev/urandom" in
        match%map Reader.peek urandom ~len:32 with
        | `Ok bytes -> assert (String.length bytes = 32) ; 
            let secret = secret_key_of_string bytes in
            let public = public_of_secret secret in
            Deferred.Or_error.return {secret; public}
        | `Eof -> Deferred.Or_error.error_string "eof before full 32 bytes read from /dev/urandom"

    let id {public; _} =
        let raw_bytes = string_of_key public in
        let sha256 = Digestif.SHA256.(digest_string raw_bytes |> to_raw_string) in
        let mh = Bytes.create (String.length sha256 + 2) in
        Bytes.set mh 0 '\x12' ;
        Bytes.set mh 1 '\x20' ;
        Bytes.From_string.blit ~src:sha256 ~src_pos:0 ~dst:mh ~dst_pos:2 ~len:(String.length sha256) ;
        B58.encode alphabet mh |> Bytes.to_string

    let safe_secret
end

module Multiaddr = struct
    type t = string

    let to_string t = t

    let of_string t = t
end

module Pubsub = struct
    type topic = string

    module Subscription = struct
        type t = { net: net_t; topic: topic}

        let publish {net; topic} message = Deferred.Or_error.return ()

        let unsubscribe _t = Deferred.Or_error.return ()
    end

    let topic_of_string s = Deferred.Or_error.return s

    let subscribe (net:net_t) topic out_pipe =
        Deferred.return (Ok {Subscription.net; topic})

    let register_validator net topic ~f = ()
end

let create ~me ~rpcs =
    let open Deferred.Or_error.Let_syntax in
    let%map helper = Helper.create () in
    Helper.do_rpc helper (`List [`String "configure"; `Assoc ["privk", Keypair.safe_secret me]])
    {helper}

let peers net = Deferred.return []

let random_peers net count = Deferred.return []

let rpc_peer net who rpc_func rpc_input = Deferred.Or_error.error_string "failed to do RPC"

let listen_on t ma = Deferred.Or_error.error_string "cannot listen"

let shutdown net = Deferred.return (Ok ())