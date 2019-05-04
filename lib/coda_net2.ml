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
  | `String s ->
    (try 
      Ok (Bytes.of_string s |> B58.decode alphabet |> Bytes.to_string)
    with
    | B58.Invalid_base58_character -> Or_error.error_string "invalid base58")
  | j ->
      Or_error.error_string "expected a string"

let to_b58_data (s : string) =
  B58.encode alphabet (Bytes.of_string s) |> Bytes.to_string

let to_int_res x = match Yojson.Safe.Util.to_int_option x with | Some i -> Ok i | None -> Or_error.error_string "needed an int"
let to_string_res x = match Yojson.Safe.Util.to_string_option x with | Some i -> Ok i | None -> Or_error.error_string "needed a string"

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
    let open Or_error.Let_syntax in
    let%bind seq = v |> member "seqno" |> to_int_res in
    let err = v |> member "error" in
    let res = v |> member "success" in
    let fill_result = match err, res with
          | `Null, r ->
              Ok r
          | e, `Null ->
            Or_error.errorf
                   "RPC #%d failed: %s" seq (Yojson.Safe.to_string e)
          | _, _ ->
              (Or_error.errorf "unexpected response to RPC #%d: %s" seq (Yojson.Safe.to_string v))
    in
    match Hashtbl.find_and_remove t.outstanding_requests seq with
    | Some ivar -> Ivar.fill ivar fill_result ; Ok ()
    | None ->  Or_error.errorf "spurious reply to RPC #%d: %s" seq (Yojson.Safe.to_string v)

  let handle_upcall t v =
    let open Yojson.Safe.Util in
    let open Or_error.Let_syntax in
    match member "upcall" v |> to_string with
    | "publish" -> (
        let%bind idx = v |> member "subscription_idx" |> to_int_res in
        let%bind data = v |> member "data" |> of_b58_data in
        match Hashtbl.find t.subscriptions idx with
        | Some sub ->
            Strict_pipe.Writer.write sub
              (Envelope.Incoming.wrap ~data ~sender:Envelope.Sender.Local) ; 
            Ok ()
        | None -> 

            Or_error.errorf "message published with inactive subsubscription %d" idx ) ;
        
    | "validate" -> (
        let%bind peerid = v |> member "peer_id" |> to_string_res in
        let%bind data = v |> member "data" |> of_b58_data in
        let%bind topic = v |> member "topic" |> to_string_res in
        let%bind seqno = v |> member "seqno" |> to_int_res in
        match Hashtbl.find t.validators topic with
        | Some v ->
            (let open Deferred.Let_syntax in let%map is_valid = v ~peerid ~data in
             Writer.write
               (Process.stdin t.subprocess)
               (Yojson.Safe.to_string
                  (`Assoc
                    [("seqno", `Int seqno); ("is_valid", `Bool is_valid)])))
            |> don't_wait_for ;
            Ok ()
        | None ->
            Or_error.errorf
              "asked to validate message for topic we haven't registered a \
               validator for %s"
              topic )
    | s ->
        Or_error.errorf "unknown upcall %s" s

  let create logger () =
    let open Deferred.Or_error.Let_syntax in
    let%map subprocess =
      Process.create ~prog:"go" ~args:["run"; "libp2p_helper/main.go"] ()
    in
    let t =
      { subprocess
      ; outstanding_requests= Hashtbl.create (module Int)
      ; subscriptions= Hashtbl.create (module Int)
      ; validators= Hashtbl.create (module String)
      ; seqno= ref 1
      ; finished= false }
    in
    let err = Process.stderr subprocess in
    let errlines = Reader.lines err in
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
    Pipe.iter errlines ~f:(fun line -> Core.eprintf "#:%s\n%!" line ; Deferred.unit)
    |> don't_wait_for ;
    Pipe.iter lines ~f:(fun line ->
        let open Yojson.Safe.Util in
        Core.eprintf ">:%s\n%!" line ;
        let v = Yojson.Safe.from_string line in
        (match (if member "upcall" v = `Null then handle_response t v
        else handle_upcall t v) with
        | Ok () -> ()
        | Error e -> Core.eprintf "handling line from helper failed: %s\n%!" (Error.to_string_hum e) )
        ;
        Deferred.unit )
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
      Writer.write_line (Process.stdin t.subprocess) rpc ;
      Core.eprintf "<:%s\n%!" rpc ;
      Ivar.read res )
    else Deferred.Or_error.error_string "helper process already exited"
end

type net = {helper: Helper.t}

type peer_id = string

(* We hardcode support for only Ed25519 keys so we can keygen without calling go *)
module Keypair = struct
  type t = {secret: string; public: string}

  let random net =
    match%map Helper.do_rpc net.helper "generateKeypair" [] with
    | Ok (`Assoc [("privk", `String secret); ("pubk", `String public)]) ->
        let open Or_error.Let_syntax in
        let%bind secret = of_b58_data (`String secret) in
        let%map public = of_b58_data (`String public) in
        {secret; public}
    | Ok j ->
        Or_error.errorf "daemon broke RPC protocol: generateKeypair got %s"
          (Yojson.Safe.to_string j)
    | Error e ->
        Error e

  let safe_secret {secret; _} = to_b58_data secret
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
        Or_error.errorf "daemon broke RPC protocol: publish got %s"
          (Yojson.Safe.to_string v)
    | Error e ->
        Error e

  module Subscription = struct
    type t =
      { net: net
      ; topic: topic
      ; idx: int
      ; pipe:
          ( string Envelope.Incoming.t
          , Strict_pipe.crash Strict_pipe.buffered
          , unit )
          Strict_pipe.Writer.t }

    let publish {net; topic; idx= _; pipe= _} message =
      publish net ~topic ~data:message

    let unsubscribe {net; idx; pipe; topic= _} =
      Strict_pipe.Writer.close pipe ;
      match%map
        Helper.do_rpc net.helper "unsubscribe" [("subscription_idx", `Int idx)]
      with
      | Ok (`String "unsubscribe success") ->
          Ok ()
      | Ok v ->
          Or_error.errorf "daemon broke RPC protocol: unsubscribe got %s"
            (Yojson.Safe.to_string v)
      | Error e ->
          Error e
  end

  let subscribe (type a) (net : net) (topic : string)
      (out_pipe :
        ( string Envelope.Incoming.t
        , a Strict_pipe.buffered
        , unit )
        Strict_pipe.Writer.t) =
    let sub_num = Helper.genseq net.helper in
    let cast_pipe :
        ( string Envelope.Incoming.t
        , Strict_pipe.crash Strict_pipe.buffered
        , unit )
        Strict_pipe.Writer.t =
      Obj.magic out_pipe
    in
    Hashtbl.add_exn net.helper.subscriptions ~key:sub_num ~data:cast_pipe ;
    match%map
      Helper.do_rpc net.helper "subscribe"
        [("topic", `String topic); ("subscription_idx", `Int sub_num)]
    with
    | Ok (`String "subscribe success") ->
        Ok {Subscription.net; topic; idx= sub_num; pipe= cast_pipe}
    | Ok v ->
        Or_error.errorf "daemon broke RPC protocol: unsubscribe got %s"
          (Yojson.Safe.to_string v)
    | Error e ->
        Error e

  let register_validator net topic ~f =
    match Hashtbl.find net.helper.validators topic with
    | Some _ ->
        Deferred.Or_error.error_string
          "already have a validator for that topic"
    | None -> (
        let idx = Helper.genseq net.helper in
        Hashtbl.add_exn net.helper.validators ~key:topic ~data:f ;
        match%map
          Helper.do_rpc net.helper "registerValidator"
            [("topic", `String topic); ("idx", `Int idx)]
        with
        | Ok (`String "register validator success") ->
            Ok ()
        | Ok v ->
            Or_error.errorf "daemon broke RPC protocol: registerValidator got %s"
              (Yojson.Safe.to_string v) 
        | Error e ->
            Error e )
end

let create logger () =
  let open Deferred.Or_error.Let_syntax in
  let%map helper = Helper.create logger () in
  {helper}

let configure {helper} ~me ~maddrs ~statedir ~network_id ~rpcs =
    match%map 
    Helper.do_rpc helper "configure"
      [ ("privk", `String (Keypair.safe_secret me))
      ; ("statedir", `String statedir)
      ; ("ifaces", `List (List.map ~f:(fun s -> `String (Multiaddr.to_string s)) maddrs))
      ; ("network_id", `String network_id) ]
      with 
    | Ok (`String "configure success") -> Ok ()
    | Ok j ->
            Or_error.errorf "daemon broke RPC protocol: configure got %s"
              (Yojson.Safe.to_string j)
    | Error e -> Error e

let peers net = Deferred.return []

let random_peers net count = Deferred.return []

let rpc_peer net who rpc_func rpc_input =
  Deferred.Or_error.error_string "failed to do RPC"

let listen_on net ma =
  match%map
    Helper.do_rpc net.helper "listen"
      [("iface", `String (Multiaddr.to_string ma))]
  with
  | Ok (`List maddrs) ->
    let lots = List.map ~f:(fun s -> Or_error.map ~f:Multiaddr.of_string (to_string_res s )) maddrs in
    Or_error.combine_errors lots
  | Ok v ->
      Or_error.errorf "daemon broke RPC protocol: listen got %s"
        (Yojson.Safe.to_string v) 
  | Error e ->
      Error e

let shutdown net = Deferred.return (Ok ())
