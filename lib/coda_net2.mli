(** An interface to limited libp2p functionality for Coda to use. *)

open Core
open Async

(** Handle to all network functionality. *)
type t

(** Essentially a hash of a public key. *)
type peer_id

module Keypair : sig
  type t

  (** Securely generate a new keypair. *)
  val random : unit -> t

  val id : t -> peer_id
end

module Multiaddr : sig
  type t

  val to_string : t -> string

  val of_string : string -> t
end

module Pubsub : sig
  type topic

  (** A subscription to a pubsub topic. *)
  module Subscription : sig
    type t

    (** Publish a message to this pubsub topic.
    *
    * Returned deferred is resolved once the publish is enqueued. *)
    val publish : t -> bytes -> unit Deferred.Or_error.t

    (** Unsubscribe from this topic, closing the write pipe.
    *
    * Returned deferred is resolved once the unsubscription is complete. *)
    val unsubscribe : t -> unit Deferred.Or_error.t
  end

  (** Get the topic handle for a string.
    *
    * You can think of this as hashing the string.
    *)
  val topic_of_string : string -> topic Deferred.Or_error.t

  (** Subscribe to a pubsub topic.
    *
    * Fails if already subscribed. If it succeeds, incoming messages for that
    * topic will be written to the pipe.
    *)
  val subscribe :
       t
    -> topic
    -> (bytes Envelope.Incoming.t, _, _) Strict_pipe.Writer.t
    -> Subscription.t Deferred.Or_error.t

  (** Validate messages on a topic with [f] before forwarding them. *)
  val register_validator :
    t -> topic -> f:(bytes Envelope.Incoming.t -> bool Deferred.t) -> unit
end

(** Create a libp2p network manager.
*
* The provided [rpcs] will be used to handle calls to [rpc_peer]>
*)
val create :
     me:Keypair.t
  -> rpcs:Host_and_port.t Rpc.Implementation.t list
  -> t Deferred.Or_error.t

(** List of all peers we know about. *)
val peers : t -> Network_peer.Peer.t list Deferred.t

(** Randomly pick a few peers from all the ones we know about. *)
val random_peers : t -> int -> Network_peer.Peer.t list Deferred.t

(** Perform Jane Street RPC with a given peer *)
val rpc_peer :
     t
  -> Network_peer.Peer.t
  -> (Versioned_rpc.Connection_with_menu.t -> 'q -> 'r Deferred.Or_error.t)
  -> 'q
  -> 'r Deferred.Or_error.t

(** Try listening on a multiaddr.
*
* If successful, returns an alternate version of the multiaddr that other
* nodes can use to connect. For example, if listening on
* ["/ip4/127.0.0.1/tcp/0"], it might return ["/ip4/127.0.0.1/tcp/35647"]
* after the OS selects an available listening port.
*)
val listen_on : t -> Multiaddr.t -> Multiaddr.t Deferred.Or_error.t

(** Stop listening, close all connections and subscription pipes. *)
val shutdown : t -> unit Deferred.Or_error.t