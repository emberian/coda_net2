open Core

module Stable = struct
  module V1 = struct
    module T = struct
      type t = Local | Remote of string
      [@@deriving sexp, bin_io]
    end

    include T
  end

  module Latest = V1

  module Module_decl = struct
    let name = "envelope_sender"

    type latest = Latest.t
  end
end

(* bin_io intentionally omitted in deriving list *)
type t = Stable.Latest.t = Local | Remote of string
[@@deriving sexp]