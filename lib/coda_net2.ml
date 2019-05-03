open Core
open Async
open Async_unix
open Deferred.Let_syntax

[@@@ocaml.warning "-27"]

module Strict_pipe = Strict_pipe
module Envelope = Envelope

(* BTC alphabet *)
let alphabet =
  B58.make_alphabet
    "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  let of_b58_data = function
  | `String s -> Bytes.of_string s |> B58.decode alphabet |> Bytes.to_string
  | j -> failwith "expected a string"

let to_b58_data (s:string) = B58.encode alphabet (Bytes.of_string s) |> Bytes.to_string

module Helper = struct
  type t =
    { subprocess: Process.t
    ; outstanding_requests: (int, Yojson.Safe.json Or_error.t Ivar.t) Hashtbl.t
    ; seqno: int ref
    ; subscriptions:
        ( int
        , ( string Envelope.Incoming.t
          , Strict_pipe.crash Strict_pipe.buffered
          , unit )
          Strict_pipe.Writer.t )
        Hashtbl.t
    ; validators:
        (string, peerid:string -> data:string -> bool Deferred.t) Hashtbl.t
    ; mutable finished: bool }

  let handle_response t v =
    let open Yojson.Safe.Util in
    let seq = v |> member "seqno" |> to_int in
    let err = v |> member "error" in
    let res = v |> member "result" in
    Hashtbl.change t.outstanding_requests seq ~f:(function
      | Some ivar ->
          ( match (err, res) with
          | `Null, r ->
              Ivar.fill ivar (Ok r)
          | e, `Null ->
              Ivar.fill ivar
                (Or_error.error_string
                   (sprintf "RPC #%d failed: %s" seq (Yojson.Safe.to_string e)))
          | _, _ ->
              eprintf "neither an error nor a result :(\n%!" ) ;
          None
      | None ->
          eprintf "spurious reply to RPC #%d: %s\n%!" seq
            (Yojson.Safe.to_string v) ;
          None )

  let handle_upcall t v =
    let open Yojson.Safe.Util in
    match member "upcall" v |> to_string with
    | "publish" -> (
        let idx = v |> member "subscription_idx" |> to_int in
        let data = v |> member "data" |> of_b58_data in
        match Hashtbl.find t.subscriptions idx with
        | Some sub ->
            Strict_pipe.Writer.write sub
              (Envelope.Incoming.wrap ~data ~sender:Envelope.Sender.Local)
        | None ->
            eprintf "message published with inactive subsubscription %d" idx )
    | "validate" -> (
        let peerid = v |> member "peer_id" |> to_string in
        let data = v |> member "data" |> of_b58_data in
        let topic = v |> member "topic" |> to_string in
        let seqno = v |> member "seqno" |> to_int in
        match Hashtbl.find t.validators topic with
        | Some v ->
            (let%map is_valid = v ~peerid ~data in
             Writer.write
               (Process.stdin t.subprocess)
               (Yojson.Safe.to_string
                  (`Assoc
                    [("seqno", `Int seqno); ("is_valid", `Bool is_valid)])))
            |> don't_wait_for
        | None ->
            eprintf
              "asked to validate message for topic we haven't registered a \
               validator for %s"
              topic )
    | s ->
        failwithf "unknown upcall %s" s ()

  let create () =
    let open Deferred.Or_error.Let_syntax in
    let%map subprocess =
      Process.create ~prog:"go" ~args:["run"; "libp2p_helpers/main.go"] ()
    in
    let t =
      { subprocess
      ; outstanding_requests= Hashtbl.create (module Int)
      ; subscriptions= Hashtbl.create (module Int)
      ; validators= Hashtbl.create (module String)
      ; seqno= ref 1
      ; finished= false }
    in
    let lines = Process.stdout subprocess |> Reader.lines in
    (let open Deferred.Let_syntax in
    let%map exit_status = Process.wait subprocess in
    t.finished <- true ;
    eprintf
      !"libp2p_helper exited with %{sexp:Core.Unix.Exit_or_signal.t}\n%!"
      exit_status ;
    Hashtbl.iter t.outstanding_requests ~f:(fun iv ->
        Ivar.fill iv
          (Or_error.error_string "libp2p_helper process died before answering")
    ))
    |> don't_wait_for ;
    Pipe.iter lines ~f:(fun line ->
        let open Yojson.Safe.Util in
        let v = Yojson.Safe.from_string line in
        if member "upcall" v <> `Null then
          handle_response t v
        else handle_upcall t v ;
        Deferred.unit)
    |> don't_wait_for ;
    t

  let genseq t =
    let v = !(t.seqno) in
    incr t.seqno ; v

  let do_rpc t name body =
    if not t.finished then (
      let res = Ivar.create () in
      let seqno = genseq t in
      Hashtbl.add_exn t.outstanding_requests ~key:seqno ~data:res ;
      let actual_obj =
        `Assoc
          [ ("seqno", `Int seqno)
          ; ("method", `String name)
          ; ("body", `Assoc body) ]
      in
      let rpc = Yojson.Safe.to_string actual_obj in
      Writer.write (Process.stdin t.subprocess) rpc ;
      Ivar.read res )
    else Deferred.Or_error.error_string "helper process already exited"
end

type t = {helper: Helper.t}

type net_t = t

type peer_id = string

(* We hardcode support for only Ed25519 keys so we can keygen without calling go *)
module Keypair = struct
  open Callipyge

  type t = {secret: secret key; public: public key}

  let random () =
    let%bind urandom = Reader.open_file "/dev/urandom" in
    match%bind Reader.peek urandom ~len:32 with
    | `Ok bytes ->
        assert (String.length bytes = 32) ;
        let secret = secret_key_of_string bytes in
        let public = public_of_secret secret in
        Deferred.Or_error.return {secret; public}
    | `Eof ->
        Deferred.Or_error.error_string
          "eof before full 32 bytes read from /dev/urandom"

  let id {public; _} =
    let raw_bytes = string_of_key public in
    let sha256 = Digestif.SHA256.(digest_string raw_bytes |> to_raw_string) in
    let mh = Bytes.create (String.length sha256 + 2) in
    Bytes.set mh 0 '\x12' ;
    Bytes.set mh 1 '\x20' ;
    Bytes.From_string.blit ~src:sha256 ~src_pos:0 ~dst:mh ~dst_pos:2
      ~len:(String.length sha256) ;
    B58.encode alphabet mh |> Bytes.to_string

  let safe_secret {secret; _} = to_b58_data (string_of_key secret)
end

module Multiaddr = struct
  type t = string

  let to_string t = t

  let of_string t = t
end

module Pubsub = struct
  type topic = string

  let publish net ~topic ~data =
    match%map
      Helper.do_rpc net.helper "publish"
        [("topic", `String topic); ("data", `String (to_b58_data data))]
    with
    | Ok (`String "publish success") ->
        Ok ()
    | Ok v ->
        failwithf "daemon broke RPC protocol: publish got %s"
          (Yojson.Safe.to_string v) ()
    | Error e ->
        Error e

  module Subscription = struct
    type t = {net: net_t; topic: topic; idx: int; pipe: ( string Envelope.Incoming.t
          , Strict_pipe.crash Strict_pipe.buffered
          , unit )
          Strict_pipe.Writer.t}

    let publish {net; topic; idx= _; pipe= _} message = publish net ~topic ~data:message

    let unsubscribe {net; idx; pipe; topic= _} =
      Strict_pipe.Writer.close pipe ;
      match%map
        Helper.do_rpc net.helper "unsubscribe" [("subscription_idx", `Int idx)]
      with
      | Ok (`String "unsubscribe success") ->
          Ok ()
      | Ok v ->
          failwithf "daemon broke RPC protocol: unsubscribe got %s"
            (Yojson.Safe.to_string v) ()
      | Error e ->
          Error e
  end

  let subscribe (net : net_t) topic out_pipe =
    let sub_num = Helper.genseq net.helper in
    Hashtbl.add_exn net.helper.subscriptions ~key:sub_num ~data:(Obj.magic out_pipe :
    ( string Envelope.Incoming.t
          , Strict_pipe.crash Strict_pipe.buffered
          , unit )
          Strict_pipe.Writer.t
    ) ;
    match%map
      Helper.do_rpc net.helper "subscribe"
        [("topic", `String topic); ("subscription_idx", `Int sub_num)]
    with
    | Ok (`String "subscribe success") ->
        Ok ()
    | Ok v ->
        failwithf "daemon broke RPC protocol: unsubscribe got %s"
          (Yojson.Safe.to_string v) ()
    | Error e ->
        Error e

  let register_validator net topic ~f = ()
end

let create ~me ~statedir ~network_id ~rpcs =
  let open Deferred.Or_error.Let_syntax in
  let%bind helper = Helper.create () in
  let%map _ =
    Helper.do_rpc helper "configure"
      [ ("privk", `String (Keypair.safe_secret me))
      ; ("statedir", `String statedir)
      ; ("network_id", `String network_id) ]
  in
  {helper}

let peers net = Deferred.return []

let random_peers net count = Deferred.return []

let rpc_peer net who rpc_func rpc_input =
  Deferred.Or_error.error_string "failed to do RPC"

let listen_on t ma = Deferred.Or_error.error_string "cannot listen"

let shutdown net = Deferred.return (Ok ())
