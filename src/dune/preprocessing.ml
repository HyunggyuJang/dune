open! Stdune
open Import
open Build.O
open Dune_file
module SC = Super_context

(* Encoded representation of a set of library names + scope *)
module Key : sig
  (* This module implements a bi-directional function between [encoded] and
     [decoded] *)
  type encoded = Digest.t

  module Decoded : sig
    type t = private
      { pps : Lib_name.t list
      ; project_root : Path.Source.t option
      }

    val of_libs : Lib.t list -> t
  end

  (* [decode y] fails if there hasn't been a previous call to [encode] such that
     [encode x = y]. *)
  val encode : Decoded.t -> encoded

  val decode : encoded -> Decoded.t
end = struct
  type encoded = Digest.t

  module Decoded = struct
    (* Values of type type are preserved in a global table between builds, so
       they must not embed values that are not safe to keep between builds, such
       as [Dune_project.t] values *)
    type t =
      { pps : Lib_name.t list
      ; project_root : Path.Source.t option
      }

    let equal x y =
      List.equal Lib_name.equal x.pps y.pps
      && Option.equal Path.Source.equal x.project_root y.project_root

    let to_string { pps; project_root } =
      let s = String.enumerate_and (List.map pps ~f:Lib_name.to_string) in
      match project_root with
      | None -> s
      | Some dir ->
        sprintf "%s (in project: %s)" s (Path.Source.to_string_maybe_quoted dir)

    let of_libs libs =
      let pps =
        (let compare a b = Lib_name.compare (Lib.name a) (Lib.name b) in
         List.sort libs ~compare)
        |> List.map ~f:Lib.name
      in
      let project =
        List.fold_left libs ~init:None ~f:(fun acc lib ->
            let scope_for_key =
              let info = Lib.info lib in
              let status = Lib_info.status info in
              match status with
              | Private scope_name -> Some scope_name
              | Public _
              | Installed ->
                None
            in
            match (acc, scope_for_key) with
            | Some a, Some b ->
              assert (Dune_project.equal a b);
              acc
            | Some _, None -> acc
            | None, Some _ -> scope_for_key
            | None, None -> None)
      in
      { pps; project_root = Option.map project ~f:Dune_project.root }
  end

  (* This mutable table is safe. Even though it can have stale entries remaining
     from previous runs, the entries themselves are correct, so this seems
     harmless apart from the lack of error in [decode] in this situation. *)
  let reverse_table : (Digest.t, Decoded.t) Table.t =
    Table.create (module Digest) 128

  let encode ({ Decoded.pps; project_root } as x) =
    let y = Digest.generic (pps, project_root) in
    match Table.find reverse_table y with
    | None ->
      Table.set reverse_table y x;
      y
    | Some x' ->
      if Decoded.equal x x' then
        y
      else
        User_error.raise
          [ Pp.textf "Hash collision between set of ppx drivers:"
          ; Pp.textf "- cache : %s" (Decoded.to_string x')
          ; Pp.textf "- fetch : %s" (Decoded.to_string x)
          ]

  let decode y =
    match Table.find reverse_table y with
    | Some x -> x
    | None ->
      User_error.raise
        [ Pp.textf "I don't know what ppx rewriters set %s correspond to."
            (Digest.to_string y)
        ]
end

let pped_module m ~f =
  let pped = Module.pped m in
  Module.iter m ~f:(fun ml_kind file ->
      let pp_path =
        Module.file pped ~ml_kind |> Option.value_exn
        |> Path.as_in_build_dir_exn
      in
      let file = Path.as_in_build_dir_exn file.path in
      f ml_kind file pp_path);
  pped

module Driver = struct
  module M = struct
    module Info = struct
      let name = Sub_system_name.make "ppx.driver"

      type t =
        { loc : Loc.t
        ; flags : Ordered_set_lang.Unexpanded.t
        ; as_ppx_flags : Ordered_set_lang.Unexpanded.t
        ; lint_flags : Ordered_set_lang.Unexpanded.t
        ; main : string
        ; replaces : (Loc.t * Lib_name.t) list
        }

      type Sub_system_info.t += T of t

      let loc t = t.loc

      (* The syntax of the driver sub-system is part of the main dune syntax, so
         we simply don't create a new one.

         If we wanted to make the ppx system an extension, then we would create
         a new one. *)
      let syntax = Stanza.syntax

      open Dune_lang.Decoder

      let decode =
        fields
          (let+ loc = loc
           and+ flags = Ordered_set_lang.Unexpanded.field "flags"
           and+ as_ppx_flags =
             Ordered_set_lang.Unexpanded.field "as_ppx_flags"
               ~check:(Dune_lang.Syntax.since syntax (1, 2))
           and+ lint_flags = Ordered_set_lang.Unexpanded.field "lint_flags"
           and+ main = field "main" string
           and+ replaces =
             field "replaces" (repeat (located Lib_name.decode)) ~default:[]
           in
           { loc; flags; as_ppx_flags; lint_flags; main; replaces })

      let encode t =
        let open Dune_lang.Encoder in
        let lib (_loc, name) = Lib_name.encode name in
        ( (1, 0)
        , record_fields
          @@ [ field_i "flags" Ordered_set_lang.Unexpanded.encode t.flags
             ; field_i "lint_flags" Ordered_set_lang.Unexpanded.encode
                 t.lint_flags
             ; field "main" string t.main
             ; field_l "replaces" lib t.replaces
             ] )
    end

    (* The [lib] field is lazy so that we don't need to fill it for hardcoded
       [t] values used to implement the jbuild style handling of drivers.

       See [Jbuild_driver] below for details. *)
    type t =
      { info : Info.t
      ; lib : Lib.t Lazy.t
      ; replaces : t list Or_exn.t
      }

    let desc ~plural =
      "ppx driver"
      ^
      if plural then
        "s"
      else
        ""

    let desc_article = "a"

    let lib t = Lazy.force t.lib

    let replaces t = t.replaces

    let instantiate ~resolve ~get lib (info : Info.t) =
      { info
      ; lib = lazy lib
      ; replaces =
          (let open Result.O in
          Result.List.map info.replaces ~f:(fun ((loc, name) as x) ->
              let* lib = resolve x in
              match get ~loc lib with
              | None ->
                Error
                  (User_error.E
                     (User_error.make ~loc
                        [ Pp.textf "%S is not a %s" (Lib_name.to_string name)
                            (desc ~plural:false)
                        ]))
              | Some t -> Ok t))
      }

    let public_info t =
      let open Result.O in
      let+ replaces = t.replaces in
      { Info.loc = t.info.loc
      ; flags = t.info.flags
      ; as_ppx_flags = t.info.as_ppx_flags
      ; lint_flags = t.info.lint_flags
      ; main = t.info.main
      ; replaces =
          List.map2 t.info.replaces replaces ~f:(fun (loc, _) t ->
              (loc, Lib.name (Lazy.force t.lib)))
      }
  end

  include M
  include Sub_system.Register_backend (M)

  (* Where are we called from? *)
  type loc =
    | User_file of Loc.t * (Loc.t * Lib_name.t) list
    | Dot_ppx of Path.Build.t * Lib_name.t list

  let make_error loc msg =
    match loc with
    | User_file (loc, _) ->
      Error (User_error.E (User_error.make ~loc [ Pp.text msg ]))
    | Dot_ppx (path, pps) ->
      Error
        (User_error.E
           (User_error.make
              ~loc:(Loc.in_file (Path.build path))
              [ Pp.textf "Failed to create on-demand ppx rewriter for %s; %s"
                  (String.enumerate_and (List.map pps ~f:Lib_name.to_string))
                  (String.uncapitalize msg)
              ]))

  let select libs ~loc =
    match select_replaceable_backend libs ~replaces with
    | Ok _ as x -> x
    | Error No_backend_found ->
      let msg =
        match
          List.filter_map libs ~f:(fun lib ->
              match Lib_name.to_string (Lib.name lib) with
              | ("ocaml-migrate-parsetree" | "ppxlib" | "ppx_driver") as s ->
                Some s
              | _ -> None)
        with
        | [] ->
          let pps =
            match loc with
            | User_file (_, pps) -> List.map pps ~f:snd
            | Dot_ppx (_, pps) -> pps
          in
          sprintf
            "No ppx driver were found. It seems that %s %s not compatible with \
             Dune. Examples of ppx rewriters that are compatible with Dune are \
             ones using ocaml-migrate-parsetree, ppxlib or ppx_driver."
            (String.enumerate_and (List.map pps ~f:Lib_name.to_string))
            ( match pps with
            | [ _ ] -> "is"
            | _ -> "are" )
        | names ->
          sprintf
            "No ppx driver were found.\nHint: Try upgrading or reinstalling %s."
            (String.enumerate_and names)
      in
      make_error loc msg
    | Error (Too_many_backends ts) ->
      make_error loc
        (sprintf "Too many incompatible ppx drivers were found: %s."
           (String.enumerate_and
              (List.map ts ~f:(fun t -> Lib_name.to_string (Lib.name (lib t))))))
    | Error (Other exn) -> Error exn
end

let ppx_exe sctx ~key =
  Path.Build.relative (SC.build_dir sctx) (".ppx/" ^ key ^ "/ppx.exe")

let build_ppx_driver sctx ~dep_kind ~target ~pps ~pp_names =
  let ctx = SC.context sctx in
  let mode = Context.best_mode ctx in
  let link_mode : Link_mode.t =
    match mode with
    | Byte -> Byte_with_stubs_statically_linked_in
    | Native -> Native
  in
  let compiler = Context.compiler ctx mode in
  let jbuild_driver, pps, pp_names = (None, pps, pp_names) in
  let driver_and_libs =
    let open Result.O in
    Result.map_error
      ~f:(fun e ->
        (* Extend the dependency stack as we don't have locations at this point *)
        Dep_path.prepend_exn e (Preprocess pp_names))
      (let* pps = pps in
       let* pps = Lib.closure ~linking:true pps in
       match jbuild_driver with
       | None ->
         let+ driver = Driver.select pps ~loc:(Dot_ppx (target, pp_names)) in
         (driver, pps)
       | Some driver -> Ok (driver, pps))
  in
  (* CR-someday diml: what we should do is build the .cmx/.cmo once and for all
     at the point where the driver is defined. *)
  let dir = Path.Build.parent_exn target in
  let ml = Path.Build.relative dir "_ppx.ml" in
  let add_rule ~sandbox = SC.add_rule ~sandbox sctx ~dir in
  let open Build.With_targets.O in
  add_rule ~sandbox:Sandbox_config.default
    ( Build.of_result_map driver_and_libs ~f:(fun (driver, _) ->
          Build.return (sprintf "let () = %s ()\n" driver.info.main))
    |> Build.write_file_dyn ml );
  add_rule ~sandbox:Sandbox_config.no_special_requirements
    ( Build.with_no_targets
        (Build.record_lib_deps
           (Lib_deps.info ~kind:dep_kind (Lib_deps.of_pps pp_names)))
    >>> Command.run compiler ~dir:(Path.build ctx.build_dir)
          [ A "-g"
          ; A "-o"
          ; Target target
          ; A "-w"
          ; A "-24"
          ; As
              ( match link_mode with
              | Byte_with_stubs_statically_linked_in ->
                [ Ocaml_version.custom_or_output_complete_exe ctx.version ]
              | Byte
              | Native ->
                [] )
          ; Command.of_result
              (Result.map driver_and_libs ~f:(fun (_driver, libs) ->
                   Command.Args.S
                     [ Lib.L.compile_and_link_flags ~mode:link_mode
                         ~compile:libs ~link:libs
                     ; Hidden_deps
                         (Lib_file_deps.deps libs ~groups:[ Cmi; Cmx ])
                     ]))
          ; Dep (Path.build ml)
          ] )

let get_rules sctx key =
  let exe = ppx_exe sctx ~key in
  let pps, pp_names =
    let names, lib_db =
      match Digest.from_hex key with
      | None ->
        User_error.raise
          [ Pp.textf "invalid ppx key for %s"
              (Path.Build.to_string_maybe_quoted exe)
          ]
      | Some key ->
        let { Key.Decoded.pps; project_root } = Key.decode key in
        let lib_db =
          match project_root with
          | None -> SC.public_libs sctx
          | Some dir ->
            let dir =
              Path.Build.append_source (Super_context.build_dir sctx) dir
            in
            Scope.libs (SC.find_scope_by_dir sctx dir)
        in
        (pps, lib_db)
    in
    let pps =
      Lib.DB.resolve_pps lib_db (List.map names ~f:(fun x -> (Loc.none, x)))
    in
    (pps, names)
  in
  build_ppx_driver sctx ~pps ~pp_names ~dep_kind:Required ~target:exe

let gen_rules sctx components =
  match components with
  | [ key ] -> get_rules sctx key
  | _ -> ()

let ppx_driver_exe sctx libs =
  let key = Digest.to_string (Key.Decoded.of_libs libs |> Key.encode) in
  ppx_exe sctx ~key

let get_cookies ~loc ~expander ~lib_name libs =
  let expander, library_name_cookie =
    match lib_name with
    | None -> (expander, None)
    | Some lib_name ->
      let library_name = Lib_name.Local.to_string lib_name in
      let bindings =
        Pform.Map.singleton "library_name" (Values [ String library_name ])
      in
      ( Expander.add_bindings expander ~bindings
      , Some ("library-name", (library_name, Lib_name.of_local (loc, lib_name)))
      )
  in
  Result.try_with (fun () ->
      List.concat_map libs ~f:(fun t ->
          let info = Lib.info t in
          let kind = Lib_info.kind info in
          match kind with
          | Normal -> []
          | Ppx_rewriter { cookies }
          | Ppx_deriver { cookies } ->
            List.map
              ~f:(fun { Lib_kind.Ppx_args.Cookie.name; value } ->
                (name, (Expander.expand_str expander value, Lib.name t)))
              cookies)
      |> (fun l ->
           match library_name_cookie with
           | None -> l
           | Some cookie -> cookie :: l)
      |> String.Map.of_list_reducei
           ~f:(fun name ((val1, lib1) as res) (val2, lib2) ->
             if String.equal val1 val2 then
               res
             else
               let lib1 = Lib_name.to_string lib1 in
               let lib2 = Lib_name.to_string lib2 in
               User_error.raise ~loc
                 [ Pp.textf
                     "%s and %s have inconsistent requests for cookie %S; %s \
                      requests %S and %s requests %S"
                     lib1 lib2 name lib1 val1 lib2 val2
                 ])
      |> String.Map.foldi ~init:[] ~f:(fun name (value, _) acc ->
             (name, value) :: acc)
      |> List.rev
      |> List.concat_map ~f:(fun (name, value) ->
             [ "--cookie"; sprintf "%s=%S" name value ]))

let ppx_driver_and_flags_internal sctx ~loc ~expander ~lib_name ~flags libs =
  let open Result.O in
  let flags = List.map ~f:(Expander.expand_str expander) flags in
  let+ cookies = get_cookies ~loc ~lib_name ~expander libs in
  let sctx = SC.host sctx in
  (ppx_driver_exe sctx libs, flags @ cookies)

let ppx_driver_and_flags sctx ~lib_name ~expander ~scope ~loc ~flags pps =
  let open Result.O in
  let* libs = Lib.DB.resolve_pps (Scope.libs scope) pps in
  let* exe, flags =
    ppx_driver_and_flags_internal sctx ~loc ~expander ~lib_name ~flags libs
  in
  let+ driver =
    Lib.closure libs ~linking:true >>= Driver.select ~loc:(User_file (loc, pps))
  in
  (exe, driver, flags)

let workspace_root_var = String_with_vars.virt_var __POS__ "workspace_root"

let promote_correction fn build ~suffix =
  Build.progn
    [ build
    ; Build.with_no_targets
        (Build.return
           (Action.diff ~optional:true (Path.build fn)
              (Path.Build.extend_basename fn ~suffix)))
    ]

let chdir action = Action_unexpanded.Chdir (workspace_root_var, action)

let action_for_pp ~dep_kind ~loc ~expander ~action ~src ~target =
  let action = chdir action in
  let bindings = Pform.Map.input_file (Path.build src) in
  let expander = Expander.add_bindings expander ~bindings in
  let targets = Targets.Or_forbidden.Forbidden "preprocessing actions" in
  let targets_dir = Option.value ~default:src target |> Path.Build.parent_exn in
  let action =
    Action_unexpanded.expand action ~loc ~expander ~dep_kind ~targets
      ~targets_dir
      (let+ () = Build.path (Path.build src) in
       Bindings.empty)
  in
  match target with
  | None -> action
  | Some dst ->
    Build.With_targets.map
      ~f:(Action.with_stdout_to dst)
      (Build.With_targets.add ~targets:[ dst ] action)

(* Generate rules for the dialect modules in [modules] and return a a new module
   with only OCaml sources *)
let setup_dialect_rules sctx ~dir ~dep_kind ~expander (m : Module.t) =
  let ml = Module.ml_source m in
  Module.iter m ~f:(fun ml_kind f ->
      match Dialect.preprocess f.dialect ml_kind with
      | None -> ()
      | Some (loc, action) ->
        let src = Path.as_in_build_dir_exn f.path in
        let dst =
          Option.value_exn (Module.file ml ~ml_kind) |> Path.as_in_build_dir_exn
        in
        SC.add_rule sctx ~dir
          (action_for_pp ~dep_kind ~loc ~expander ~action ~src
             ~target:(Some dst)));
  ml

let add_corrected_suffix_binding expander suffix =
  let bindings =
    Pform.Map.singleton "corrected-suffix" (Values [ String suffix ])
  in
  Expander.add_bindings expander ~bindings

let driver_flags expander ~flags ~corrected_suffix ~driver_flags ~standard =
  let args : _ Command.Args.t = S [ As flags ] in
  let ppx_flags =
    let expander = add_corrected_suffix_binding expander corrected_suffix in
    Build.memoize "ppx flags"
      (Expander.expand_and_eval_set expander driver_flags ~standard)
  in
  (ppx_flags, args)

let lint_module sctx ~dir ~expander ~dep_kind ~lint ~lib_name ~scope =
  Staged.stage
    (let alias = Alias.lint ~dir in
     let add_alias fn build =
       SC.add_alias_action sctx alias build ~dir ~stamp:("lint", lib_name, fn)
     in
     let lint =
       Module_name.Per_item.map lint ~f:(function
         | Preprocess.No_preprocessing -> fun ~source:_ ~ast:_ -> ()
         | Future_syntax loc ->
           User_error.raise ~loc
             [ Pp.text "'compat' cannot be used as a linter" ]
         | Action (loc, action) ->
           fun ~source ~ast:_ ->
             Module.iter source ~f:(fun _ (src : Module.File.t) ->
                 let src = Path.as_in_build_dir_exn src.path in
                 add_alias src ~loc:(Some loc)
                   (action_for_pp ~dep_kind ~loc ~expander ~action ~src
                      ~target:None))
         | Pps { loc; pps; flags; staged } ->
           if staged then
             User_error.raise ~loc
               [ Pp.text "Staged ppx rewriters cannot be used as linters." ];
           let corrected_suffix = ".lint-corrected" in
           let driver_and_flags =
             let open Result.O in
             let+ exe, driver, flags =
               ppx_driver_and_flags sctx ~expander ~loc ~lib_name ~flags ~scope
                 pps
             in
             let ppx_flags, args =
               driver_flags expander ~flags ~corrected_suffix
                 ~driver_flags:driver.info.lint_flags
                 ~standard:(Build.return [])
             in
             (exe, ppx_flags, args)
           in
           fun ~source ~ast ->
             Module.iter ast ~f:(fun ml_kind src ->
                 add_alias src.path ~loc:None
                   (promote_correction ~suffix:corrected_suffix
                      (Path.as_in_build_dir_exn
                         (Option.value_exn (Module.file source ~ml_kind)))
                      (Build.With_targets.of_result_map ~targets:[]
                         driver_and_flags ~f:(fun (exe, flags, args) ->
                           Command.run
                             ~dir:(Path.build (SC.build_dir sctx))
                             (Ok (Path.build exe))
                             [ args
                             ; Command.Ml_kind.ppx_driver_flag ml_kind
                             ; Dep src.path
                             ; Command.Args.dyn flags
                             ])))))
     in
     fun ~(source : Module.t) ~ast ->
       Module_name.Per_item.get lint (Module.name source) ~source ~ast)

type t = (Module.t -> lint:bool -> Module.t) Module_name.Per_item.t

let dummy = Module_name.Per_item.for_all (fun m ~lint:_ -> m)

let make sctx ~dir ~expander ~dep_kind ~lint ~preprocess ~preprocessor_deps
    ~lib_name ~scope =
  let preprocess =
    Module_name.Per_item.map preprocess ~f:(fun pp ->
        Preprocess.remove_future_syntax ~for_:Compiler pp
          (Super_context.context sctx).version)
  in
  let preprocessor_deps =
    Dep_conf_eval.unnamed preprocessor_deps ~expander
    |> Build.memoize "preprocessor deps"
  in
  let lint_module =
    Staged.unstage
      (lint_module sctx ~dir ~expander ~dep_kind ~lint ~lib_name ~scope)
  in
  Module_name.Per_item.map preprocess ~f:(fun pp ->
      match pp with
      | No_preprocessing ->
        fun m ~lint ->
          let ast = setup_dialect_rules sctx ~dir ~dep_kind ~expander m in
          if lint then lint_module ~ast ~source:m;
          ast
      | Action (loc, action) ->
        fun m ~lint ->
          let ast =
            pped_module m ~f:(fun _kind src dst ->
                let action =
                  action_for_pp ~dep_kind ~loc ~expander ~action ~src
                    ~target:(Some dst)
                in
                let open Build.With_targets.O in
                SC.add_rule sctx ~loc ~dir
                  (Build.with_no_targets preprocessor_deps >>> action))
            |> setup_dialect_rules sctx ~dir ~dep_kind ~expander
          in
          if lint then lint_module ~ast ~source:m;
          ast
      | Pps { loc; pps; flags; staged } ->
        if not staged then (
          let corrected_suffix = ".ppx-corrected" in
          let driver_and_flags =
            let open Result.O in
            let+ exe, driver, flags =
              ppx_driver_and_flags sctx ~expander ~loc ~lib_name ~flags ~scope
                pps
            in
            let ppx_flags, args =
              driver_flags expander ~flags ~corrected_suffix
                ~driver_flags:driver.info.flags
                ~standard:(Build.return [ "--as-ppx" ])
            in
            (exe, ppx_flags, args)
          in
          fun m ~lint ->
            let open Build.With_targets.O in
            let ast = setup_dialect_rules sctx ~dir ~dep_kind ~expander m in
            if lint then lint_module ~ast ~source:m;
            pped_module ast ~f:(fun ml_kind src dst ->
                SC.add_rule ~sandbox:Sandbox_config.no_special_requirements sctx
                  ~loc ~dir
                  (promote_correction ~suffix:corrected_suffix
                     (Path.as_in_build_dir_exn
                        (Option.value_exn (Module.file m ~ml_kind)))
                     ( Build.with_no_targets preprocessor_deps
                     >>> Build.With_targets.of_result_map driver_and_flags
                           ~targets:[ dst ] ~f:(fun (exe, flags, args) ->
                             Command.run
                               ~dir:(Path.build (SC.build_dir sctx))
                               (Ok (Path.build exe))
                               [ args
                               ; A "-o"
                               ; Target dst
                               ; Command.Ml_kind.ppx_driver_flag ml_kind
                               ; Dep (Path.build src)
                               ; Command.Args.dyn flags
                               ]) )))
        ) else
          let pp_flags =
            Build.of_result
              (let open Result.O in
              let+ exe, driver, flags =
                ppx_driver_and_flags sctx ~expander ~loc ~scope ~flags ~lib_name
                  pps
              in
              Build.memoize "ppx command"
                (let open Build.O in
                let+ () = Build.path (Path.build exe)
                and+ () = preprocessor_deps
                and+ driver_flags =
                  Expander.expand_and_eval_set expander driver.info.as_ppx_flags
                    ~standard:(Build.return [ "--as-ppx" ])
                in
                let command =
                  List.map
                    (List.concat
                       [ [ Path.reach (Path.build exe)
                             ~from:(Path.build (SC.build_dir sctx))
                         ]
                       ; driver_flags
                       ; flags
                       ])
                    ~f:String.quote_for_shell
                  |> String.concat ~sep:" "
                in
                [ "-ppx"; command ]))
          in
          let pp = Some pp_flags in
          fun m ~lint ->
            let ast = setup_dialect_rules sctx ~dir ~dep_kind ~expander m in
            if lint then lint_module ~ast ~source:m;
            Module.set_pp ast pp)

let pp_module t ?(lint = true) m =
  Module_name.Per_item.get t (Module.name m) m ~lint

let pp_module_as t ?(lint = true) name m =
  Module_name.Per_item.get t name m ~lint

let get_ppx_driver sctx ~loc ~expander ~scope ~lib_name ~flags pps =
  let open Result.O in
  let* libs = Lib.DB.resolve_pps (Scope.libs scope) pps in
  ppx_driver_and_flags_internal sctx ~loc ~expander ~lib_name ~flags libs

let ppx_exe sctx ~scope pp =
  let open Result.O in
  let+ libs = Lib.DB.resolve_pps (Scope.libs scope) [ (Loc.none, pp) ] in
  ppx_driver_exe sctx libs
