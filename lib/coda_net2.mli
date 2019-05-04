(** An interface to limited libp2p functionality for Coda to use. *)

open Core
open Async

module Strict_pipe : module type of Strict_pipe
module Envelope : module type of Envelope

(** Handle to all network functionality. *)
type net

(** Essentially a hash of a public key. *)
type peer_id

module Keypair : sig
  type t

  (** Securely generate a new keypair. *)
  val random : net -> t Deferred.Or_error.t
end

module Multiaddr : sig
  type t

  val to_string : t -> string

  val of_string : string -> t
end

module Pubsub : sig
  (** A subscription to a pubsub topic. *)
  module Subscription : sig
    type t

    (** Publish a message to this pubsub topic.
    *
    * Returned deferred is resolved once the publish is enqueued. *)
    val publish : t -> string -> unit Deferred.Or_error.t

    (** Unsubscribe from this topic, closing the write pipe.
    *
    * Returned deferred is resolved once the unsubscription is complete. *)
    val unsubscribe : t -> unit Deferred.Or_error.t
  end

  (** Publish a message to a topic.
  *
  * Returned deferred is resolved once the publish is enqueued *)
  val publish : net -> topic:string -> data:string -> unit Deferred.Or_error.t

  (** Subscribe to a pubsub topic.
    *
    * Fails if already subscribed. If it succeeds, incoming messages for that
    * topic will be written to the pipe.
    *)
  val subscribe :
       net
    -> string
    -> (string Envelope.Incoming.t, _  Strict_pipe.buffered, unit) Strict_pipe.Writer.t
    -> Subscription.t Deferred.Or_error.t

  (** Validate messages on a topic with [f] before forwarding them. *)
  val register_validator :
    net -> string -> f:(peerid:string -> data:string -> bool Deferred.t) -> unit Deferred.Or_error.t
end

val create : unit -> unit -> net Deferred.Or_error.t

(** Configure the network connection.
*
* The provided [rpcs] will be used to handle calls to [rpc_peer].
*)
val configure :
     net
  -> me:Keypair.t
  -> maddrs:Multiaddr.t list
  -> statedir:string
  -> network_id:string
  -> rpcs:Host_and_port.t Rpc.Implementation.t list
  -> unit Deferred.Or_error.t

(** List of all peers we know about. *)
val peers : net -> Peer.t list Deferred.t

(** Randomly pick a few peers from all the ones we know about. *)
val random_peers : net -> int -> Peer.t list Deferred.t

(** Perform Jane Street RPC with a given peer *)
val rpc_peer :
     net
  -> Peer.t
  -> (Versioned_rpc.Connection_with_menu.t -> 'q -> 'r Deferred.Or_error.t)
  -> 'q
  -> 'r Deferred.Or_error.t

(** Try listening on a multiaddr.
*
* If successful, returns the list of all addresses this net is listening on.
* For example, if listening on ["/ip4/127.0.0.1/tcp/0"], it might return
* ["/ip4/127.0.0.1/tcp/35647"] after the OS selects an available listening
* port.
*)
val listen_on : net -> Multiaddr.t -> Multiaddr.t list Deferred.Or_error.t

(** Stop listening, close all connections and subscription pipes. *)
val shutdown : net -> unit Deferred.Or_error.t