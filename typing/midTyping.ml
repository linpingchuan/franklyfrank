open MidTree
open ParseTree
open ListUtils

exception TypeError of string

module ENV = Map.Make(String)

type effect_var = EVempty | EVone

type effect_env = src_type list * effect_var  

type env =
  {
    tenv : ENV.t; (** Type environment mapping variables to their types. *)
    fenv : effect_env; (** Effect environment *)
    cset : (src_type * src_type) list; (** Constraint set for unifying type
					   variables. *)
  }

let just_hdrs = function Mtld_handler hdr -> Some hdr | _ -> None

let rec type_prog prog =
  let tenv = ENV.add "Bool" TypeExp.bool
    (ENV.add "Int" TypExp.int ENV.empty) in
  let env = { tenv; fenv = ([], EVone); cset = [] } in
  let ts = List.map (type_tld env) prog in
  let hdrs = filter_map just_hdrs prog in
  match filter (fun (ts,h) -> h.mhdr_name = "main") (zip ts hdrs) with
  | [(t,_)] -> t
  | _
    -> raise (TypeError ("There must exist a unique main function"))

and type_tld env d =
  match d with
  | Mtld_datatype dt -> type_datatype env dt
  | Mtld_effin    ei -> type_effect_interface env ei
  | Mtld_handler  h  -> type_hdr env h

and type_datatype env dt = TypExp.rigid_tvar(dt.sdt_name)

and type_effect_interface env ei = TypExp.rigid_tvar(ei.sei_name)

and type_hdr env h =
  let _ = type_clauses env h.mhdr_type h.mhdr_defs in
  h.mhdr_type

and type_pattern (arg, p) =
  (** TODO: Consult some enviornment to determine the type of p
      and compare to arg. *)
  raise (TypeError "Expecting typeof(arg) got typeof(p)")

(** env |- res checks cc *)
and type_ccomp env res cc =
  match cc with
  | Mccomp_cvalue  cv  -> type_cvalue env res cv
  | Mccomp_clauses cls -> type_clauses env res cls

and type_clauses env t cls =
  (** This is wrong: no arrow type here *)
  let (args,res) = destruct_arrow_type t in foldl (type_clause args) res cls

and type_clause args res (ps, cc) =
  try
    let env  = pat_matches args ps in
    type_ccomp env res cc
  with
  | TypeError s -> Debug.print "%s...\n" s; exit(-1)

and pat_matches args ps =
  foldl type_pattern ENV.empty (zip args ps)

and type_pattern env (t, p) = raise (TypeError ("Pattern match fail"))

and destruct_arrow_type t =
  let rec f t rargs =
    match t with
    | Styp_arrow a b -> f b (a :: rargs)
    | _ -> (List.rev rargs, t)
  in f t []

(** env |- res checks cv *)
and type_cvalue env res cv =
  match cv with
  | Mcvalue_ivalue iv
    -> let t = type_ivalue env iv in
       unify res t
  | Mcvalue_ctr (k, vs), Styp_ctr (k', ts)
    -> if k = k' then type_ctr env ts k vs
       else raise (TypeError ("Expecting " ^ k' ^ " got " ^ k))
  | Mcvalue_thunk cc    -> type_ccomp env res cc (** TODO: Add
						     coverage checking *)
and type_ctr env res k vs =
  let env' = foldl (type_cvalue env) ENV.empty vs in
  

(** env |- iv infers (type_ivalue env iv) *)
and type_ivalue env iv =
  match iv with
  | Mivalue_var v -> type_var env v
  | Mivalue_sig s -> type_sig env s
  | Mivalue_int _ -> TypExp.int
  | Mivalue_bool _ -> TypExp.bool
  | Mivalue_icomp ic -> type_icomp env ic

and type_icomp env ic =
  match ic with
  | Micomp_app (iv, cs) ->

and type_var env res v =
  try
    if ENV.find v env = res then res
    else raise (TypeError ("var type mismatch"))
  with
  | Not_found -> raise (TypeError ("No such var " ^ v))

  