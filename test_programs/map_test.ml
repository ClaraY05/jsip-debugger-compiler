open! Base

module Account_id = struct
  module T = struct
    type t = string
  end

  let of_string t = t
  include T
  include Comparable.Make (T)
end

module Price = struct
  type t = int
end

type action = Add of (Account_id.t * Price.t)

type bank = Price.t Map.M(Account_id).t

let piggy_bank = ref (Map.empty (module Account_id));;

let day1 = [Add (Account_id.of_string "John",1),
            Add (Account_id.of_string "John",2),
            Add (Account_id.of_string "Johny",3)]

(* this is wrong but it's fine *)
let loop day =
  let perform action =
    match action with
    | Add a, p -> piggy_bank := Map.set !piggy_bank ~key:a ~data:p
  in
  List.iter perform day


let () = loop day1
