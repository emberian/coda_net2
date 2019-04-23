module Stable = struct
  module V1 = struct
    module T = struct
      type t = Local | Remote of Peer.Stable.V1.t
      [@@deriving sexp, bin_io]
    end

    include T
    include Registration.Make_latest_version (T)
  end

  module Latest = V1

  module Module_decl = struct
    let name = "envelope_sender"

    type latest = Latest.t
  end

  module Registrar = Registration.Make (Module_decl)
  module Registered_V1 = Registrar.Register (V1)
end

(* bin_io intentionally omitted in deriving list *)
type t = Stable.Latest.t = Local | Remote of Peer.t
[@@deriving sexp]