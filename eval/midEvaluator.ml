(***********************************************************************
 * Evaluate the mid-level language.
 *
 *
 * Created by Craig McLaughlin on 21/07/2015.
 ***********************************************************************
 *)

open MidTranslate
open MidTree
open MidTyping
open Monad
open ParseTree
open ParseTreeBuilder
open PatternMatching
open Printf
open ListUtils

module type EVALCOMP = sig
  include MONAD

  type comp = value t
  and value =
    | VBool of bool
    | VInt of int
    | VFloat of float
    | VStr of string
    | VCon of string * value list
    | VMultiHandler of (comp list -> comp)

  module type EVALENVT = sig
    include Map.S with type key := string
    type mt = comp t
  end

  module ENV : EVALENVT

  val (>=>) : (value -> 'a t) -> ('a -> 'b t) -> value -> 'b t
  val sequence : ('a t) list -> ('a list) t
  val command : string -> value list -> comp
  val show : comp -> string
  val vshow : value -> string

  val eval_dtree : ENV.mt -> comp list -> dtree -> comp
  (** [eval_dtree cs t] evaluates the decision tree [t] w.r.t the stack of
      computations [cs] returning a computaton. The stack is assumed to
      initially hold the subject value. *)

  val eval : MidTranslate.HandlerMap.mt -> MidTree.prog -> comp
end

module EvalComp : EVALCOMP = struct
  exception UserDefShadowingBuiltin of string

  type 'a t =
    | Command of string * value list * (value -> 'a t)
    | Return of 'a

  and comp = value t

  and value =
    | VBool of bool
    | VInt of int
    | VFloat of float
    | VStr of string
    | VCon of string * value list
    | VMultiHandler of (comp list -> comp)

  module type EVALENVT = sig
    include Map.S with type key := string
    type mt = comp t
  end

  module ENV = struct
    module M = Map.Make(String)
    include M
    type mt = comp M.t
  end

  (** Monadic operations *)
  let return v = Return v

  let rec (>=>) f g x = f x >>= g
  and (>>=) m k =
    match m with
    | Command (c, vs, r) -> Command (c, vs, r >=> k)
    | Return v           -> k v

  let lift : (value -> comp) -> value = fun f ->
    VMultiHandler (fun [m] -> m >>= f)

  let rec sequence = function
    | []      -> return []
    | m :: ms -> m >>= (fun x -> sequence ms >>= (fun xs -> return (x :: xs)))

  let command c vs = Command (c, vs, return)

  let rec vshow v =
    match v with
    | VBool b -> string_of_bool b
    | VInt n -> string_of_int n
    | VFloat f -> string_of_float f
    | VStr s -> "\"" ^ (String.escaped s) ^ "\""
    | VCon ("Nil", []) -> "[]"
    | VCon ("Cons", vs) ->
      let rec show_vs =
        function
        | [v; VCon ("Nil", [])] -> vshow v
        | [v; VCon ("Cons", vs)] -> vshow v ^ ", " ^ show_vs vs
      in
      "[" ^ show_vs vs ^ "]"
    | VCon (k, []) -> k
    | VCon (k, vs) -> "(" ^ k ^ (string_of_args " " vshow vs) ^ ")"
    | VMultiHandler _ -> "MULTIHANDLER"

  let show c =
    match c with
    | Command (c, vs, _)
      -> "Command (" ^ c ^ (string_of_args " " vshow vs) ^ ")"
    | Return v
      -> "Return (" ^ vshow v ^ ")"

  let is_some ox = match ox with Some _ -> true | _ -> false

  let len_cmp vs vs' = List.length vs = List.length vs'
  let foldr = List.fold_right

  (** match a value against a type signature and return the updated value and
      any child values. *)
  let match_value_sig env v tsg =
    match v, tsg with
    | _, TSAllValues None -> Some (env, [])
    | _, TSAllValues (Some x) -> Some (ENV.add x (return v) env, [])
    | VBool b, TSBool b' -> if b = b' then Some (env, []) else None
    | VInt n, TSInt n' -> if n = n' then Some (env, []) else None
    | VFloat f, TSFloat f' -> if f = f' then Some (env, []) else None
    | VStr s, TSStr s' -> if s = s' then Some (env, []) else None
    | VCon (k, vs), TSCtr (k', n)
      -> if k = k' && length vs = n then
	  Some (env, map return vs)
	else None
    | _ , _ -> None

  let match_cmd_sig env (c, vs, r) tsg =
    match tsg with
    | TSCmd (c', n)
      -> if c = c' then Some (env, map return (vs ++ [(lift r)])) else None
    | _ -> None

  (** Top-level matching procedure which will return None or a pair of an
      updated environment and any child values to be matched. *)
  let match_sig env c tsg =
    match c with
    | Return v -> match_value_sig env v tsg
    | Command (cmd, vs, r) -> match_cmd_sig env (cmd, vs, r) tsg

  (* Return v is matched by x
   * Return (suc v) is matched by suc x and x *)
  let rec match_value (v, p) oenv =
    match oenv with
    | None -> None
    | Some env ->
      begin
	match v, p with
	| _, Svpat_any -> Some env
	| _, Svpat_var x -> if ENV.mem x env then None
                            else Some (ENV.add x (return v) env)
	| VBool b, Svpat_bool b' -> if b = b' then Some env else None
	| VInt n, Svpat_int n' -> if n = n' then Some env else None
	| VFloat f, Svpat_float f' -> if f = f' then Some env else None
	| VStr s, Svpat_str s' -> if s = s' then Some env else None
	| VCon (k, vs), Svpat_ctr (k', vs')
	  -> if k = k' && len_cmp vs vs' then
	      let oenv = foldr match_value (zip vs vs') (Some env) in
	      begin
		match oenv with
		| None -> None
		| Some env -> Some (ENV.add k (return (VCon (k, vs))) env)
	      end
	    else None
	| _ -> None
      end

  (* Command ("put", [v], r) is matched by [put x -> k] and [?c -> k] and
     [t] *)
  let match_command (c, vs, r) p env =
    match p with
    | Scpat_request (c', vs', r')
      -> if c = c' && c' <> r' && len_cmp vs vs' then
	  let oenv = foldr match_value (zip vs vs') (Some env) in
	  begin
	    match oenv with
	    | None -> None
	    | Some env -> if ENV.mem c env then	None (*uniq cond*)
	                  else Some (ENV.add r' (return (lift r))
				       (ENV.add c (Command (c, vs, r)) env))
	  end
	else None

  let match_pair (c, p) oenv =
    match oenv with
    | None -> None
    | Some env ->
      begin
	match c, p.spat_desc with
	(* NOTE: this is where the problem of forwarding lies. We are not
	   checking the command; these patterns only match if the command is
	   in the type signature of this argument. Is this information
	   available here? I guess this point is moot now that we are doing
	   compilation in separate steps. *)
	| _ , Spat_any -> Some env
	| _ , Spat_thunk thk ->
	  (* Return a suspended computation that will just perform the inner
	     computation when forced. *)
	  Some (ENV.add thk (return (VMultiHandler (fun cs -> c))) env)
	| Command (c', vs, r), Spat_comp cp
	  -> match_command (c', vs, r) cp env
	| Return v, Spat_value vp
	  -> match_value (v, vp) (Some env)
	| _ -> None
      end

  let pat_matches cs ps =
    if List.length cs > List.length ps then
      raise (invalid_arg "too many arguments")
    else if List.length cs < List.length ps then
      raise (invalid_arg "too few arguments")
    else
      List.fold_right match_pair (List.combine cs ps) (Some ENV.empty)

  let just_hdrs = function Mtld_handler hdr -> Some hdr | _ -> None

  (** Anonymous handler counter *)
  let anonhdr = ref 0

  (** Builtin functions *)
  let gtdef env [cx; cy] = cx >>=
    function (VInt x) -> cy >>=
      (function (VInt y) -> return (VBool (x > y))
               | _ as vy -> invalid_arg ("second_arg:" ^ vshow vy))
            | _ as vx -> invalid_arg ("first arg:" ^ vshow vx)

  let gtfdef env [cx; cy] = cx >>=
    function (VFloat x) -> cy >>=
      (function (VFloat y) -> return (VBool (x > y))
               | _ as vy -> invalid_arg ("second_arg:" ^ vshow vy))
            | _ as vx -> invalid_arg ("first arg:" ^ vshow vx)

  let minusdef env [cx; cy] = cx >>=
    function (VInt x) -> cy >>=
      (function (VInt y) -> return (VInt (x - y))
               | _ as vy -> invalid_arg ("second_arg:" ^ vshow vy))
            | _ as vx -> invalid_arg ("first arg:" ^ vshow vx)

  let plusdef env [cx; cy] = cx >>=
    function (VInt x) -> cy >>=
      (function (VInt y) -> return (VInt (x + y))
               | _ as vy -> invalid_arg ("second_arg:" ^ vshow vy))
            | _ as vx -> invalid_arg ("first arg:" ^ vshow vx)

  let strcatdef env [cx; cy] = cx >>=
    function (VStr x) -> cy >>=
      (function (VStr y) -> return (VStr (x ^ y))
               | _ as vy -> invalid_arg ("second arg:" ^ vshow vy))
            | _ as vx -> invalid_arg ("first arg:" ^ vshow vx)

  (** Create the builtin environment. *)
  let get_builtins () =
    let blts = [("gt", gtdef); ("gtf", gtfdef); ("minus", minusdef);
		("plus", plusdef); ("strcat", strcatdef)] in
    let add_blt (n,d) env = ENV.add n d env in
    List.fold_right add_blt blts ENV.empty

  let rec eval hmap prog =
    let blt_env = get_builtins () in
    let hdrs = List.map (fun (k, h) -> h) (HandlerMap.bindings hmap) in
    let pre_env = List.fold_right construct_env_entry hdrs blt_env in
    let rec env' =
      lazy (ENV.map (fun f ->
	return (VMultiHandler (fun cs -> f (Lazy.force env') cs))) pre_env) in
    let env = Lazy.force env' in
    let main = ENV.find "main" env in
    main >>= function VMultiHandler f -> rts (f [])
                     |      _         -> not_hdr ~desc:"main" ()

  (* The runtime system handles some commands such as I/O. *)
  and rts m =
    match m with
    | Command _ -> rts (handle_builtin_cmds m)
    | Return v -> m

  and handle_builtin_cmds m =
    match m with
    | Command ("random",   [], r) -> r (VFloat (Random.float 1.0))
    | Command ("putStr",   [VStr s], r) -> print_string s;
                                           r (VCon ("Unit", []))
    | Command ("putStrLn", [VStr s], r) -> print_endline s;
                                           r (VCon ("Unit", []))
    | Command ("getStr",   [],  r)      -> r (VStr (read_line ()))
    | Command (c, _, _) -> failwith ("Command: " ^ c ^ " not handled")
    |    _     -> assert false (* Command not handled *)

  and construct_env_entry hdr env =
    if ENV.mem hdr.mhdr_name env then
      raise (UserDefShadowingBuiltin hdr.mhdr_name)
    else
      ENV.add hdr.mhdr_name (fun env cs ->
	Debug.print "Evaluating handler %s...\n" hdr.mhdr_name;
	eval_tlhdrs env hdr cs) env

  (* Give precedence to ob. *)
  and extend_env name oa ob =
    match ob with
    | Some _ -> ob
    | None -> oa

  and eval_tlhdrs env hdr cs =
    let cls = hdr.mhdr_defs in
    match List.fold_left (eval_clause env cs) None cls with
    | None -> fwd_clauses env hdr cs
    | Some c -> c

  and eval_clause env cs res (ps, cc) =
    match res with
    | Some _ -> res
    | None
      -> begin
	   Debug.print "%s with %s..."
	     (string_of_args ", " ~bbegin:false show cs)
	     (string_of_args ", " ~bbegin:false ShowPattern.show ps);
           match pat_matches cs ps with
	   | Some env'
	     -> (* Extend env with shadowing environment env'. *)
                let env'' = ENV.merge extend_env env env' in
		Debug.print "true\n"; Some (eval_ccomp env'' cc)
	   | None -> Debug.print "false\n"; None
         end

  and fwd_clauses env hdr cs =
    List.fold_right (fwd_cls env hdr) (diag (gen_cpats cs)) pat_match_fail

  and repeat x n = if n <= 0 then [] else x :: (repeat x (n-1))

  and gen_cpats xs =
    let n = List.length xs in
    List.combine (repeat [] n) (repeat xs n)

  and diag = function
    | (ys, x :: xs) :: xss -> (ys, x, xs) :: diag (List.map shift xss)
    |           _          ->             []

  and shift = function
    | (ys, x :: xs) -> (x :: ys, xs)
    |    _  as p    ->       p

  and fwd_cls env hdr (cs1, c, cs2) acc =
    match c with
    | Command (s, vs, r)
      -> command s vs >>=
           fun z -> let cs = (List.rev cs1) @ [r z] @ cs2 in
		    eval_tlhdrs env hdr cs
    | _ -> acc

  and pat_match_fail = command "PatternMatchFail" []

  and app_if_ne s t =
    s ^ (if t <> "" then " : " ^ t else t)

  and unhandled_comp ?(desc = "") () =
    command (app_if_ne "UnhandledComputation" desc) []

  and not_hdr ?(desc = "") () =
    command (app_if_ne "NotAHandler" desc) []

  and eval_ccomp env cc =
    match cc with
    | Mccomp_cvalue cv -> eval_cvalue env cv
    | Mccomp_clauses [] -> command "NoClausesProbablyShouldNotGetHere" []
    | Mccomp_clauses cls
      -> return (VMultiHandler (fun cs -> eval_mid_clauses env cls cs))

  and eval_mid_clauses env cls cs =
    let t = TypExp.fresh_rigid_tvar "AnonMH" in
    let n =
      match t.styp_desc with
      | Styp_rtvar (_, n) -> n
      | _ -> assert false in
    let hdr =
      {
	mhdr_name = "AnonMH" ^ (string_of_int n);
	mhdr_type = t;
	mhdr_defs = cls
      }
    in eval_tlhdrs env hdr cs

  and eval_cvalue env cv =
    match cv with
    | Mcvalue_ivalue iv -> eval_ivalue env iv
    | Mcvalue_ctr (k, vs)
      -> sequence (List.map (eval_cvalue env) vs) >>=
         fun vs -> return (VCon (k, vs))
    | Mcvalue_thunk (Mccomp_cvalue cv) ->
      return (VMultiHandler (fun [] -> eval_cvalue env cv))
    | Mcvalue_thunk cc ->
      eval_ccomp env cc

  and eval_ivalue env iv =
    match iv with
    | Mivalue_var v -> ENV.find v env
    | Mivalue_cmd c -> eval_cmd env c
    | Mivalue_int n -> return (VInt n)
    | Mivalue_float f -> return (VFloat f)
    | Mivalue_bool b -> return (VBool b)
    | Mivalue_str s -> return (VStr s)
    | Mivalue_icomp ic -> eval_icomp env ic

  and eval_icomp env ic =
    match ic with
    | Micomp_app (iv, cs) -> eval_app env iv cs
    | Micomp_let (x, cc1, cc2)
      -> eval_ccomp env cc1 >>=
         fun v -> let env' = ENV.add x (return v) env in
		  eval_ccomp env' cc2

  and eval_app env u cs =
    let mhdr cs = eval_ivalue env u >>=
      function VMultiHandler f -> f cs
      | _ as v -> not_hdr ~desc:(vshow v) () in
    mhdr (List.map (eval_ccomp env) cs)

  and eval_cmd env c =
    return (VMultiHandler
	      (fun cs -> sequence cs >>= fun vs -> command c vs))

  let rec eval_dtree env cs t =
    (* Mccomp_cvalue (Mcvalue_ivalue (Mivalue_int 0)) *)
    let rec eval_case c cses =
      match cses with
      | (CseSig (tsg, t) as cse) :: cses'
	-> begin match match_sig env c tsg with
	   | Some (env', args) -> (env', args, cse)
	   | None -> eval_case c cses'
	   end
      | (CseDefault t as cse) :: cses' -> (env, [], cse)
      | _ -> failwith "No default case in switch cases list" in
    match t with
    | Leaf k -> eval_ccomp env k
    | Swap (i, t) -> eval_dtree env (swap cs 0 i) t
    | Switch cases -> let (c, cs') = (List.hd cs, List.tl cs) in
                      begin
		        match eval_case c cases with
			| (env', args, CseSig (_, t))
			  -> eval_dtree env' (args ++ cs') t
			| (env', [], CseDefault t) -> eval_dtree env cs' t
			| _ -> assert false
		      end
    | Fail -> failwith "Decision tree evaluation unexpectedly failed"




end

