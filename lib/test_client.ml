open Async

let main () =
    let kp = Coda_net2.Keypair.random () in
    let%bind net = Coda_net2.create ~me:kp ~rpcs:[] in 
    ()
;;