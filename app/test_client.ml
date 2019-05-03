open Core
open Async
open Deferred.Let_syntax
open Coda_net2

let main () =
    let open Deferred.Or_error.Let_syntax in
    let pid = Unix.getpid () |> Pid.to_int in
    let%bind kp = Coda_net2.Keypair.random () in
    let%bind net = Coda_net2.create ~me:kp ~rpcs:[] ~network_id:"test 0" ~statedir:(Format.sprintf "/tmp/libp2p-state/%d" pid) in 
    let%bind ma = Coda_net2.listen_on net (Coda_net2.Multiaddr.of_string "/ip4/0.0.0.0/tcp/0") in
    eprintf "Listening on %s\n%!" (Coda_net2.Multiaddr.to_string ma) ;
    let (rd, wr) = Strict_pipe.create ~name:"test topic messages" 
        (Buffered 
            (`Capacity 30,
            `Overflow Drop_head)) 
        in
    let%bind main_topic = Pubsub.topic_of_string net "test topic" in
    let%bind sub = Pubsub.subscribe net main_topic wr in
    Strict_pipe.Reader.iter rd ~f:(fun bytes_env ->
        eprintf !"received `%s` from %{sexp:Envelope.Sender.t} on test topic%!\n" (Envelope.Incoming.data bytes_env) (Envelope.Incoming.sender bytes_env);
        Deferred.unit
    ) |> don't_wait_for ;
    Reader.lines (Lazy.force Reader.stdin) |> Pipe.iter ~f:(fun line ->
       let open Deferred.Let_syntax in
       match%map Pubsub.Subscription.publish sub line with
       | Ok () -> eprintf "successfully sent!"
       | Error e -> eprintf "failed to send :( error=%s%!\n" (Error.to_string_hum e) 
    ) |> don't_wait_for ;
    Deferred.never ()
;;

let _ = Scheduler.go_main ~main:(fun () -> (match%bind main () with 
| Error e -> Error.raise e
| Ok () -> (eprintf "exiting..." ; exit 1)) |> don't_wait_for) ()