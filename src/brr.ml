(*---------------------------------------------------------------------------
   Copyright (c) 2018 The brr programmers. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
   %%NAME%% %%VERSION%%
  ---------------------------------------------------------------------------*)

open Note

(* Array utilities *)

let array_to_list a =
  let acc = ref [] in
  for i = a ##. length - 1 downto 0 do acc := Js.Unsafe.get a i :: !acc done;
  !acc

let array_of_list l =
  let a = new%js Js.array_empty in
  let rec loop i = function
  | [] -> a | v :: vs -> Js.array_set a i v; loop (i + 1) vs
  in
  loop 0 l

(* JavaScript strings *)

type str = Js.js_string Js.t
let str = Js.string
let strf fmt =
  let k _ = str (Format.flush_str_formatter ()) in
  Format.kfprintf k Format.str_formatter fmt

module Str = struct
  type t = str
  let empty = str ""
  let is_empty s = s ##. length = 0
  let append s0 s1 = s0 ## concat (s1)
  let cuts ~sep s = array_to_list (Js.str_array (s ## split sep))
  let concat ~sep ss = (array_of_list ss) ## join sep
  let slice ?(start = 0) ?stop s = match stop with
  | None -> s ## slice_end start
  | Some stop -> s ## slice start stop

  let trim s = (Js.Unsafe.(coerce s) ## trim ())
  let chop ~prefix s =
    let i = s ## indexOf (prefix) in
    if i <> 0 then None else
    Some (s ## substring_toEnd (prefix ##. length))

  let rchop ~suffix s =
    let i = s ## indexOf suffix in
    let suff_start = s ##. length - suffix ##. length in
    if i <> suff_start then None else
    Some (s ## substring 0 suff_start)

  let to_string = Js.to_string
  let of_string = Js.string
  let equal = ( = )
  let compare = Pervasives.compare
  let pp ppf s = Format.pp_print_string ppf (Js.to_string s)
end

module Prop = struct
  type 'a t = { path : str list ; undefined : 'a }
  let v ~undefined path = { path; undefined }
  let vstr ~undefined path = { path = List.map str path; undefined }
  let set p v o =
    let rec loop o = function
    | n :: [] -> Js.Unsafe.set o n v
    | n :: ns -> loop (Js.Unsafe.get o n) ns
    | [] -> assert false
    in
    loop o p.path

  let get p o =
    let rec loop o = function
    | n :: [] ->
        begin match Js.Optdef.to_option (Js.Unsafe.get o n) with
        | None -> p.undefined | Some v -> v
        end
    | n :: ns -> loop (Js.Unsafe.get o n) ns
    | [] -> assert false
    in
    loop o p.path

  let rget p ~on o = E.map on (fun _ -> get p o)
  let bool n = vstr ~undefined:false [n]
  let str n = vstr ~undefined:Str.empty [n]
  let checked = bool "checked"
  let id = str "id"
  let name = str "name"
  let title = str "title"
  let value = str "value"
end

module Log = struct
  type level = Quiet | App | Error | Warning | Info | Debug
  let _level = ref Debug
  let level () = !_level
  let set_level l = _level := l

  type ('a, 'b) msgf =
    (?header:string -> ('a, Format.formatter, unit, 'b) format4 -> 'a) -> 'b

  type 'a log = ('a, unit) msgf -> unit
  type kmsg = { kmsg : 'a 'b. (unit -> 'b) -> level -> ('a, 'b) msgf -> 'b }

  let pp_header ppf = function
  | None -> ()
  | Some v -> Format.fprintf ppf "[%s] " v

  let console_obj = Js.Unsafe.variable "console"
  let console : level -> string -> unit =
  fun level s ->
    let meth = match level with
    | Error -> "error"
    | Warning -> "warn"
    | Info -> "info"
    | Debug -> "debug"
    | App -> "log"
    | Quiet -> assert false
    in
    Js.Unsafe.meth_call console_obj meth [| Js.Unsafe.inject (Js.string s) |]

  let report level k msgf =
    msgf @@ fun ?header fmt ->
    let k str = console level str; k () in
    Format.kasprintf k ("%a@[" ^^ fmt ^^ "@]@.") pp_header header

  let nop_kmsg =
    let kmsg k level msgf = k () in
    { kmsg }

  let default_kmsg =
    let kmsg k level msgf = match !_level with
    | Quiet -> k ()
    | level' when level > level' -> k ()
    | _ -> report level k msgf
    in
    { kmsg }

  let _kmsg = ref default_kmsg
  let set_kmsg kmsg = _kmsg := kmsg

  let kunit _ = ()
  let msg level msgf = !_kmsg.kmsg kunit level msgf
  let app msgf = !_kmsg.kmsg kunit App msgf
  let err msgf = !_kmsg.kmsg kunit Error msgf
  let warn msgf = !_kmsg.kmsg kunit Warning msgf
  let info msgf = !_kmsg.kmsg kunit Info msgf
  let debug msgf = !_kmsg.kmsg kunit Debug msgf
  let kmsg k level msgf = !_kmsg.kmsg k level msgf
end

module Debug = struct
  external enter : unit -> unit = "debugger"
  let pp_obj ppf v =
    let s = (Js.Unsafe.coerce v) ## toString () in
    Format.pp_print_string ppf (Js.to_string s)

  let dump_obj v = Firebug.console ## debug (v)

  (* Tracing *)

  let nop ppf _ = ()
  let tick ppf _ = Format.fprintf ppf "tick"
  let trace ?(pp = nop) id v = Log.debug (fun m -> m "%s: %a" id pp v); v
  let trace_v ?(pp = tick) id v = Log.debug (fun m -> m "%s: %a" id pp v)
  let trace_v_ret ?pp id v = trace_v ?pp id v; v
  let trace_e ?(obs = false) ?pp id e = match obs with
  | true -> Logr.may_hold (E.log e (trace_v ?pp id)); e
  | false -> E.map e (trace_v_ret ?pp id)

  let trace_s ?(obs = false) ?pp id s = match obs with
  | true -> Logr.hold (S.log s (trace_v ?pp id)); s
  | false -> S.map ~eq:(S.eq s) s (trace_v_ret ?pp id)
end

module Time = struct
  type span = float

  let warn_time () =
    Log.warn (fun m -> m "performance.now () missing, using Date.now ()")

  let tick_now =
    let date_now () = ((new%js Js.date_now) ## getTime) /. 1000. in
    let perf_now () =
      (Js.Unsafe.coerce Dom_html.window) ##. performance ## now () /. 1000.
    in
    let perf = (Js.Unsafe.coerce Dom_html.window) ##. performance in
    match Js.Optdef.to_option perf with
    | None -> warn_time (); date_now
    | Some p ->
        match (Js.Unsafe.coerce p) ## now with
        | None -> warn_time (); date_now
        | Some n -> perf_now

  let start = tick_now ()
  let elapsed () = tick_now () -. start

  type counter = span
  let counter () = tick_now ()
  let counter_value c = tick_now () -. c

  let tick span =
    let e, send_e = E.create () in
    let c = counter () in
    let action () = send_e (counter_value c) in
    let ms = span *. 1000. in
    ignore (Dom_html.window ## setTimeout (Js.wrap_callback action) ms);
    e

  let pp_s ppf s = Format.fprintf ppf "%gs" s
  let pp_ms ppf s = Format.fprintf ppf "%gms" (s *. 1e3)
  let pp_mus ppf s = Format.fprintf ppf "%gμs" (s *. 1e6)
end

(* DOM *)

module Att = struct
  type name = str
  type t = name * str
  let v name v = (name, v)
  let vf name fmt =
    let k _ = (name, str (Format.flush_str_formatter ())) in
    Format.kfprintf k Format.str_formatter fmt

  let vstr name v = (str name, str v)
  let vstrf name fmt = vf (name) fmt
  let add_if b att l = if b then att :: l else l

  module Name = struct
    let autofocus = Js.string "autofocus"
    let checked = Js.string "checked"
    let disabled = Js.string "disabled"
    let for' = Js.string "for"
    let height = Js.string "height"
    let href = Js.string "href"
    let id = Js.string "id"
    let klass = Js.string "class"
    let name = Js.string "name"
    let placeholder = Js.string "placeholder"
    let src = Js.string "src"
    let tabindex = Js.string "tabindex"
    let title = Js.string "title"
    let type' = Js.string "type"
    let value = Js.string "value"
    let width = Js.string "width"
  end

  let int n i = (n, str (string_of_int i))
  let bool n = n, Str.empty
  let str n v = (n, str v)

  let autofocus = bool Name.autofocus
  let checked = bool Name.checked
  let disabled = bool Name.disabled
  let for' = str Name.for'
  let height = int Name.height
  let href = str Name.href
  let id = str Name.id
  let klass = str Name.klass
  let name = str Name.name
  let placeholder = str Name.placeholder
  let src = str Name.src
  let tabindex = int Name.tabindex
  let title = str Name.title
  let type' = str Name.type'
  let value = str Name.value
  let width = int Name.width
end

module El = struct

  type el = Dom_html.element Js.t

  (* DOM garbage collection support. We observe HTML DOM additions and
     removals on body and invoke callback registered for the
     appropriate life cycle event. In particular Note loggers from
     nodes that are removed from the HTML DOM are destroyed. *)

  let add_prop : (unit -> unit) list Prop.t = Prop.vstr ~undefined:[]["brr_add"]
  let rem_prop : (unit -> unit) list Prop.t = Prop.vstr ~undefined:[]["brr_rem"]
  let add_fun prop f (e : el) = Prop.set prop (f :: Prop.get prop e) e
  let invoke_funs prop e =
    let funs = Prop.get prop e in
    List.iter (fun f -> f ()) funs;
    Prop.set prop [] e

  let add_logr (e : el) l =
    add_fun rem_prop (fun () -> Logr.destroy l) e

  let may_add_logr (e : el) = function None -> () | Some l -> add_logr e l

  let in_html_dom n =
    (Js.Unsafe.meth_call n "getRootNode" [||] :> #Dom.node Js.t) ==
    Dom_html.document

  let obs = match MutationObserver.is_supported () with
  | false ->
      Log.warn (fun m -> m "No MutationObserver, disfunction ahead!"); Js.null
  | true ->
      let f records observer =
        for i = 0 to records ##. length - 1 do
          match Js.Optdef.to_option (Js.array_get records i) with
          | None -> ()
          | Some r ->
              let adds = r ##. addedNodes in
              for i = 0 to adds ##. length - 1 do
                match Js.Opt.to_option (adds ## item i) with
                | None -> ()
                | Some o -> if (in_html_dom o) then invoke_funs add_prop o
              done;
              let rems = r ##. removedNodes in
              for i = 0 to rems ##. length - 1 do
                match Js.Opt.to_option (rems ## item i) with
                | None -> ()
                | Some o -> if not (in_html_dom o) then invoke_funs rem_prop o
              done
        done
      in
      Js.some @@ MutationObserver.observe
        ~node:(Dom_html.document ##. documentElement :> Dom.node Js.t) ~f
        ~child_list:true ~subtree:true ~attributes:false ~character_data:false
        ~attribute_old_value:false ~character_data_old_value:false ()

  (* Elements *)

  type name = Js.js_string Js.t
  type t = [ `El of el ]
  type child = [ t | `Txt of str ]

  let add_children (`El n) children =
    let rec loop n = function
    | [] ->  ()
    | `Txt txt :: cs ->
        let txt = Dom_html.document ## createTextNode (txt) in
        ignore (n ## appendChild ((txt :> Dom.node Js.t))); loop n cs
    | `El e :: cs ->
        ignore (n ## appendChild ((e :> Dom.node Js.t))); loop n cs
    in
    loop n children

  let v ?(atts = []) name cs =
    let set_att e (a, v) = match Str.equal a Att.Name.klass with
    | true -> e ##. classList ## add (v)
    | false -> e ## setAttribute a v
    in
    let e = Dom_html.document ## createElement name in
    let el = `El e in
    List.iter (set_att e) atts;
    add_children el cs;
    el

  let find ~id =
    match Js.Opt.to_option (Dom_html.document ## getElementById id) with
    | None -> None
    | Some e -> (Some (`El e))

  let document () = `El (Dom_html.document ##. documentElement)
  let document_body () = `El (Dom_html.document ##. body)
  let el (`El e) = e

  (* Children *)

  let txt s = (`Txt (str s))
  let txtf fmt =
    let k _ = `Txt (str (Format.flush_str_formatter ())) in
    Format.kfprintf k Format.str_formatter fmt

  let rec rem_children (`El n) =
    let rec loop n = match Js.Opt.to_option (n ##. firstChild) with
    | None -> ()
    | Some c -> ignore (n ## removeChild c); loop n
    in
    loop n

  let set_children e cs = rem_children e; add_children e cs
  let rset_children e ~on =
    may_add_logr (el e) (E.log on (fun cs -> set_children e cs))

  let def_children e cs =
    add_logr (el e) (S.log cs (fun cs -> set_children e cs))

  (* Attributes *)

  let get_att a (`El e) = Js.Opt.to_option (e ## getAttribute a)
  let set_att a v (`El e) = match v with
  | None -> e ## removeAttribute a
  | Some v -> e ## setAttribute a v

  let rget_att a ~on e = E.map on (fun _ -> get_att a e)
  let rset_att a ~on e =
    may_add_logr (el e) (E.log on (fun v -> set_att a v e))

  let def_att a vs e =
    add_logr (el e) (S.log vs (fun v -> set_att a v e))

  (* Classes *)

  let get_class c (`El e) = Js.to_bool (e ##. classList ## contains c)
  let set_class c b (`El e) = match b with
  | true -> e ##. classList ## add c
  | false -> e ##. classList ## remove c

  let rget_class c ~on e = E.map on (fun _ -> get_class c e)
  let rset_class c ~on e =
    may_add_logr (el e) (E.log on (fun v -> set_class c v e))

  let def_class c bs e = add_logr (el e) (S.log bs (fun b -> set_class c b e))

  (* Properties *)

  let rget_prop p ~on (`El e) = Prop.rget p ~on e
  let rset_prop p ~on (`El e) =
    may_add_logr e (E.log on (fun v -> Prop.set p v e))

  let def_prop p vs (`El e) =
    add_logr e (S.log vs (fun v -> Prop.set p v e))

  (* Focus *)

  let set_focus b (`El e) = if b then (e ## focus) else (e ## blur)
  let rset_focus ~on (`El e as el) =
    may_add_logr e (E.log on (fun v -> set_focus v el))

  let def_focus b (`El e as el) =
    add_logr e (S.log b (fun b -> set_focus b el))

  (* Click simulation *)

  let click (`El e) = e ## click
  let select_txt (`El e) =
    match Js.Optdef.test (Js.Unsafe.coerce e) ##. select with
    | true -> (Js.Unsafe.coerce e) ## select
    | false -> ()

  (* Life-cycle callbacks *)

  let on_add f (`El e) = add_fun add_prop f e
  let on_rem f (`El e) = add_fun rem_prop f e

  (* Note loggers *)

  let call f ~on (`El e as el) = may_add_logr e (E.log on (fun v -> f v el))
  let hold_logr (`El e) l = add_logr e l
  let may_hold_logr (`El e) l = may_add_logr e l

  (* Element names *)

  module Name = struct
    let v s = Js.string s
    let a = v "a"
    let abbr = v "abbr"
    let address = v "address"
    let area = v "area"
    let article = v "article"
    let aside = v "aside"
    let audio = v "audio"
    let b = v "b"
    let base = v "base"
    let bdi = v "bdi"
    let bdo = v "bdo"
    let blockquote = v "blockquote"
    let body = v "body"
    let br = v "br"
    let button = v "button"
    let canvas = v "canvas"
    let caption = v "caption"
    let cite = v "cite"
    let code = v "code"
    let col = v "col"
    let colgroup = v "colgroup"
    let command = v "command"
    let datalist = v "datalist"
    let dd = v "dd"
    let del = v "del"
    let details = v "details"
    let dfn = v "dfn"
    let div = v "div"
    let dl = v "dl"
    let dt = v "dt"
    let em = v "em"
    let embed = v "embed"
    let fieldset = v "fieldset"
    let figcaption = v "figcaption"
    let figure = v "figure"
    let footer = v "footer"
    let form = v "form"
    let h1 = v "h1"
    let h2 = v "h2"
    let h3 = v "h3"
    let h4 = v "h4"
    let h5 = v "h5"
    let h6 = v "h6"
    let head = v "head"
    let header = v "header"
    let hgroup = v "hgroup"
    let hr = v "hr"
    let html = v "html"
    let i = v "i"
    let iframe = v "iframe"
    let img = v "img"
    let input = v "input"
    let ins = v "ins"
    let kbd = v "kbd"
    let keygen = v "keygen"
    let label = v "label"
    let legend = v "legend"
    let li = v "li"
    let link = v "link"
    let map = v "map"
    let mark = v "mark"
    let menu = v "menu"
    let meta = v "meta"
    let meter = v "meter"
    let nav = v "nav"
    let noscript = v "noscript"
    let object' = v "object"
    let ol = v "ol"
    let optgroup = v "optgroup"
    let option = v "option"
    let output = v "output"
    let p = v "p"
    let param = v "param"
    let pre = v "pre"
    let progress = v "progress"
    let q = v "q"
    let rp = v "rp"
    let rt = v "rt"
    let ruby = v "ruby"
    let s = v "s"
    let samp = v "samp"
    let script = v "script"
    let section = v "section"
    let select = v "select"
    let small = v "small"
    let source = v "source"
    let span = v "span"
    let strong = v "strong"
    let style = v "style"
    let sub = v "sub"
    let summary = v "summary"
    let sup = v "sup"
    let table = v "table"
    let tbody = v "tbody"
    let td = v "td"
    let textarea = v "textarea"
    let tfoot = v "tfoot"
    let th = v "th"
    let thead = v "thead"
    let time = v "time"
    let title = v "title"
    let tr = v "tr"
    let track = v "track"
    let u = v "u"
    let ul = v "ul"
    let var = v "var"
    let video = v "video"
    let wbr = v "wbr"
  end

  type 'a cons = ?atts:Att.t list -> child list -> ([> t] as 'a)
  let cons name ?atts cs = v ?atts name cs

  let a = cons Name.a
  let abbr = cons Name.abbr
  let address = cons Name.address
  let area = cons Name.area
  let article = cons Name.article
  let aside = cons Name.aside
  let audio = cons Name.audio
  let b = cons Name.b
  let base = cons Name.base
  let bdi = cons Name.bdi
  let bdo = cons Name.bdo
  let blockquote = cons Name.blockquote
  let body = cons Name.body
  let br = cons Name.br
  let button = cons Name.button
  let canvas = cons Name.canvas
  let caption = cons Name.caption
  let cite = cons Name.cite
  let code = cons Name.code
  let col = cons Name.col
  let colgroup = cons Name.colgroup
  let command = cons Name.command
  let datalist = cons Name.datalist
  let dd = cons Name.dd
  let del = cons Name.del
  let details = cons Name.details
  let dfn = cons Name.dfn
  let div = cons Name.div
  let dl = cons Name.dl
  let dt = cons Name.dt
  let em = cons Name.em
  let embed = cons Name.embed
  let fieldset = cons Name.fieldset
  let figcaption = cons Name.figcaption
  let figure = cons Name.figure
  let footer = cons Name.footer
  let form = cons Name.form
  let h1 = cons Name.h1
  let h2 = cons Name.h2
  let h3 = cons Name.h3
  let h4 = cons Name.h4
  let h5 = cons Name.h5
  let h6 = cons Name.h6
  let head = cons Name.head
  let header = cons Name.header
  let hgroup = cons Name.hgroup
  let hr = cons Name.hr
  let html = cons Name.html
  let i = cons Name.i
  let iframe = cons Name.iframe
  let img = cons Name.img
  let input = cons Name.input
  let ins = cons Name.ins
  let kbd = cons Name.kbd
  let keygen = cons Name.keygen
  let label = cons Name.label
  let legend = cons Name.legend
  let li = cons Name.li
  let link = cons Name.link
  let map = cons Name.map
  let mark = cons Name.mark
  let menu = cons Name.menu
  let meta = cons Name.meta
  let meter = cons Name.meter
  let nav = cons Name.nav
  let noscript = cons Name.noscript
  let object' = cons Name.object'
  let ol = cons Name.ol
  let optgroup = cons Name.optgroup
  let option = cons Name.option
  let output = cons Name.output
  let p = cons Name.p
  let param = cons Name.param
  let pre = cons Name.pre
  let progress = cons Name.progress
  let q = cons Name.q
  let rp = cons Name.rp
  let rt = cons Name.rt
  let ruby = cons Name.ruby
  let s = cons Name.s
  let samp = cons Name.samp
  let script = cons Name.script
  let section = cons Name.section
  let select = cons Name.select
  let small = cons Name.small
  let source = cons Name.source
  let span = cons Name.span
  let strong = cons Name.strong
  let style = cons Name.style
  let sub = cons Name.sub
  let summary = cons Name.summary
  let sup = cons Name.sup
  let table = cons Name.table
  let tbody = cons Name.tbody
  let td = cons Name.td
  let textarea = cons Name.textarea
  let tfoot = cons Name.tfoot
  let th = cons Name.th
  let thead = cons Name.thead
  let time = cons Name.time
  let title = cons Name.title
  let tr = cons Name.tr
  let track = cons Name.track
  let u = cons Name.u
  let ul = cons Name.ul
  let var = cons Name.var
  let video = cons Name.video
  let wbr = cons Name.wbr
end

module Ev = struct

  (* Events and event kinds *)

  type 'a target = (#Dom_html.eventTarget as 'a) Js.t
  type 'a kind = (#Dom_html.event as 'a) Js.t Dom_html.Event.typ
  type 'a t = (#Dom_html.event as 'a) Js.t

  (* Event callbacks *)

  type cb = Dom.event_listener_id
  type cb_ret = bool Js.t

  let add_cb ?(capture = false) e k cb =
    Dom.addEventListener e k (Dom.full_handler cb) (Js.bool capture)

  let rem_cb cb = Dom.removeEventListener cb

  let cb_ret ?(propagate = true) ?(default = propagate) e =
    if not default then Dom.preventDefault e;
    if not propagate then Dom_html.stopPropagation e;
    Js.bool propagate

  (* Note events *)

  let for_target ?capture ?propagate ?default t k f =
    let e, send_e = E.create () in
    let cb _ ev = send_e (f ev); cb_ret ?propagate ?default ev in
    ignore (add_cb ?capture t k cb); e

  let for_targets ?capture ?propagate ?default ts k f =
    let e, send_e = E.create () in
    let cb t ev = send_e (f t ev); cb_ret ?propagate ?default ev in
    List.iter (fun t -> ignore (add_cb ?capture t k cb)) ts; e

  let for_el ?capture ?propagate ?default (`El t) k f =
    for_target ?capture ?propagate ?default t k f

  let for_els ?capture ?propagate ?default es k f =
    let e, send_e = E.create () in
    let cb t ev = send_e (f (`El t) ev); cb_ret ?propagate ?default ev in
    List.iter (fun (`El t) -> ignore (add_cb ?capture t k cb)) es; e

  let ev e = e
  let unit e = ()
  let stamp v e = v

  (* Event kinds *)

  let kind = Dom.Event.make

  let abort = Dom.Event.make "abort"
  let afterprint = Dom.Event.make "afterprint"
  let beforeprint = Dom.Event.make "beforeprint"
  let beforeunload = Dom.Event.make "beforeunload"
  let blur = Dom.Event.make "blur"
  let cached = Dom.Event.make "cached"
  let change = Dom.Event.make "change"
  let click = Dom.Event.make "click"
  let dblclick = Dom.Event.make "dblclick"
  let domContentLoaded = Dom.Event.make "DOMContentLoaded"
  let error = Dom.Event.make "error"
  let focus = Dom.Event.make "focus"
  let hashchange = Dom.Event.make "hashchange"
  let input = Dom.Event.make "input"
  let invalid = Dom.Event.make "invalid"
  let keydown = Dom.Event.make "keydown"
  let keypress = Dom.Event.make "keypress"
  let keyup = Dom.Event.make "keyup"
  let load = Dom.Event.make "load"
  let message = Dom.Event.make "message"
  let mousedown = Dom.Event.make "mousedown"
  let mouseenter = Dom.Event.make "mouseenter"
  let mouseleave = Dom.Event.make "mouseleave"
  let mousemove = Dom.Event.make "mousemove"
  let mouseout = Dom.Event.make "mouseout"
  let mouseover = Dom.Event.make "mouseover"
  let mouseup = Dom.Event.make "mouseup"
  let offline = Dom.Event.make "offline"
  let online = Dom.Event.make "online"
  let pagehide = Dom.Event.make "pagehide"
  let pageshow = Dom.Event.make "pageshow"
  let popstate = Dom.Event.make "popstate"
  let readystatechange = Dom.Event.make "readystatechange"
  let reset = Dom.Event.make "reset"
  let resize = Dom.Event.make "resize"
  let submit = Dom.Event.make "submit"
  let unload = Dom.Event.make "unload"
end

(* User interaction *)

module Key = struct
  type code = int
  type t =
  [ `Alt of [ `Left | `Right ]
  | `Arrow of [ `Up | `Down | `Left | `Right ]
  | `Ascii of Char.t
  | `Backspace
  | `Ctrl of [ `Left | `Right ]
  | `End
  | `Enter
  | `Escape
  | `Func of int
  | `Home
  | `Insert
  | `Key of code
  | `Meta of [ `Left | `Right ]
  | `Page of [ `Up | `Down ]
  | `Return
  | `Shift of [ `Left | `Right ]
  | `Spacebar
  | `Tab ]

  (* For browser keyboard handling see http://unixpapa.com/js/key.html *)

  let of_keycode kc = match kc with
  | c when 48 <= c && c <= 57 -> `Ascii (Char.chr c)
  | c when 65 <= c && c <= 90 -> `Ascii (Char.chr (c + 32) (* to lower *))
  | c when 96 <= c && c <= 105 -> `Ascii (Char.chr (c - 96 + 48))
  | c when 112 <= c && c <= 135 -> `Func (c - 111)
  | 8 -> `Backspace
  | 9 -> `Tab
  | 13 -> `Return
  | 16 -> `Shift `Left
  | 17 -> `Ctrl `Left
  | 18 -> `Alt `Left
  | 27 -> `Escape
  | 32 -> `Spacebar
  | 33 -> `Page `Up
  | 34 -> `Page `Down
  | 35 -> `End
  | 36 -> `Home
  | 37 -> `Arrow `Left
  | 38 -> `Arrow `Up
  | 39 -> `Arrow `Right
  | 40 -> `Arrow `Down
  | 45 -> `Enter
  | 91 | 224 -> `Meta `Left
  | 93 -> `Meta `Right
  | c -> `Key c

  let of_ev e = of_keycode (e ##. keyCode)
  let equal k0 k1 = k0 = k1
  let compare k0 k1 = compare k0 k1

  let dir_to_string = function
  | `Left -> "left" | `Right -> "right" | `Up -> "up" | `Down -> "down"

  let pf = Format.fprintf
  let pp ppf = function
  | `Alt dir -> pf ppf "alt_%s" (dir_to_string dir)
  | `Arrow dir -> pf ppf "arrow_%s" (dir_to_string dir)
  | `Ascii c -> pf ppf "'%c'" c
  | `Backspace -> pf ppf "backspace"
  | `Ctrl dir -> pf ppf "ctrl_%s" (dir_to_string dir)
  | `End -> pf ppf "end"
  | `Enter -> pf ppf "enter"
  | `Escape -> pf ppf "escape"
  | `Func n -> pf ppf "f%d" n
  | `Home -> pf ppf "home"
  | `Insert -> pf ppf "insert"
  | `Key c -> pf ppf "key_%d" c
  | `Meta dir -> pf ppf "meta_%s" (dir_to_string dir)
  | `Page dir -> pf ppf "page_%s" (dir_to_string dir)
  | `Return -> pf ppf "return"
  | `Shift dir -> pf ppf "shift_%s" (dir_to_string dir)
  | `Spacebar -> pf ppf "spacebar"
  | `Tab -> pf ppf "tab"


  type events =
    { propagate : bool; default : bool;
      any_down : t event; send_any_down : ?step:Step.t -> t -> unit;
      any_up : t event; send_any_up : ?step:Step.t -> t -> unit;
      mutable down_count : int;
      any_holds : bool signal; set_any_holds : ?step:Step.t -> bool -> unit;
      down_event : (t, unit event * (?step:Step.t -> unit -> unit)) Hashtbl.t ;
      up_event : (t, unit event * (?step:Step.t -> unit -> unit)) Hashtbl.t;
      holds : (t, bool signal * (?step:Step.t -> bool -> unit)) Hashtbl.t;
      alt : bool signal; ctrl : bool signal; meta : bool signal;
      shift : bool signal; }

  let def_event event k = try fst (Hashtbl.find event k) with
  | Not_found -> let d = E.create () in Hashtbl.add event k d; fst d

  let send_event ?step event k = try snd (Hashtbl.find event k) ?step () with
  | Not_found -> ()

  let def_holds holds k = try fst (Hashtbl.find holds k) with
  | Not_found -> let d = S.create false in Hashtbl.add holds k d; fst d

  let set_holds ?step holds k v = try snd (Hashtbl.find holds k) ?step v with
  | Not_found -> ()

  let add_modifiers holds =
     let lalt = S.create false in
     let ralt = S.create false in
     let alt = S.Bool.(fst lalt || fst ralt) in
     let lctrl = S.create false in
     let rctrl = S.create false in
     let ctrl = S.Bool.(fst lctrl || fst rctrl) in
     let lmeta = S.create false in
     let rmeta = S.create false in
     let meta = S.Bool.(fst lmeta || fst rmeta) in
     let lshift = S.create false in
     let rshift = S.create false in
     let shift = S.Bool.(fst lshift || fst rshift) in
     Hashtbl.add holds (`Alt `Left) lalt;
     Hashtbl.add holds (`Alt `Right) ralt;
     Hashtbl.add holds (`Ctrl `Left) lctrl;
     Hashtbl.add holds (`Ctrl `Right) rctrl;
     Hashtbl.add holds (`Meta `Left) lmeta;
     Hashtbl.add holds (`Meta `Right) rmeta;
     Hashtbl.add holds (`Shift `Left) lshift;
     Hashtbl.add holds (`Shift `Right) rshift;
     alt, ctrl, meta, shift

  let handle_down evs ~step k =
    evs.down_count <- evs.down_count + 1 ;
    evs.send_any_down ~step k;
    evs.set_any_holds ~step true;
    send_event ~step evs.down_event k;
    set_holds ~step evs.holds k true;
    ()

  let handle_up evs ~step k =
    evs.down_count <- evs.down_count - 1;
    evs.send_any_up ~step k;
    if evs.down_count <= 0 then
      (evs.down_count <- 0; evs.set_any_holds ~step false);
    send_event ~step evs.up_event k;
    set_holds ~step evs.holds k false;
    ()

  (* Unclear how well that repeat works. Otherwise suppress
     repeats like we did in Useri. *)
  let down_cb evs _ e = match Js.(to_bool @@ (Unsafe.coerce e) ##. repeat) with
  | true -> Ev.cb_ret ~propagate:evs.propagate ~default:evs.default e
  | false ->
      let step = Step.create () in
      handle_down evs ~step (of_ev e);
      Step.execute step;
      Ev.cb_ret ~propagate:evs.propagate ~default:evs.default e

  let up_cb evs _ e =
    let step = Step.create () in
    handle_up evs ~step (of_ev e);
    Step.execute step;
    Ev.cb_ret ~propagate:evs.propagate ~default:evs.default e

  let for_target
      ?(capture = false) ?(propagate = true) ?(default = propagate) t
    =
    let hsize = 47 in
    let any_down, send_any_down = E.create () in
    let any_up, send_any_up = E.create () in
    let any_holds, set_any_holds = S.create false in
    let down_event = Hashtbl.create hsize in
    let up_event = Hashtbl.create hsize in
    let holds = Hashtbl.create hsize in
    let alt, ctrl, meta, shift = add_modifiers holds in
    let evs = { propagate; default; any_down; send_any_down; any_up;
                send_any_up; down_count = 0; any_holds; set_any_holds;
                down_event; up_event; holds; alt; ctrl; meta; shift }
    in
    ignore @@ Ev.(add_cb ~capture t keydown (down_cb evs));
    ignore @@ Ev.(add_cb ~capture t keyup (up_cb evs));
    evs

  let for_el ?capture ?propagate ?default (`El t) =
    for_target ?capture ?propagate ?default t

  let any_down evs = evs.any_down
  let any_up evs = evs.any_up
  let any_holds evs = evs.any_holds
  let down evs k = def_event evs.down_event k
  let up evs k = def_event evs.up_event k
  let holds evs k = def_holds evs.holds k
  let alt evs = evs.alt
  let ctrl evs = evs.ctrl
  let meta evs = evs.meta
  let shift evs = evs.shift
end

module Mouse = struct

  let warn_but () = Log.warn (fun m -> m "unexpected e.which")
  let pt x y = (x, y)

  type 'a events =
    { t : Dom_html.eventTarget Js.t ;
      propagate : bool; default : bool;
      normalize : bool;
      pt : float -> float -> 'a;
      mutable last_pos : float * float;
      mutable cbs : Ev.cb list; (* registered callbacks *)
      pos : 'a signal; set_pos : ?step:Step.t -> 'a -> unit;
      dpos : 'a event; send_dpos : ?step:Step.t -> 'a -> unit;
      mem : bool signal; set_mem : ?step:Step.t -> bool -> unit;
      left : bool signal; set_left : ?step:Step.t -> bool -> unit;
      left_down : 'a event; send_left_down : ?step:Step.t -> 'a -> unit;
      left_up : 'a event; send_left_up : ?step:Step.t -> 'a -> unit;
      mid : bool signal; set_mid : ?step:Step.t -> bool -> unit;
      mid_down : 'a event; send_mid_down : ?step:Step.t -> 'a -> unit;
      mid_up : 'a event; send_mid_up : ?step:Step.t -> 'a -> unit;
      right : bool signal; set_right : ?step:Step.t -> bool -> unit;
      right_down : 'a event; send_right_down : ?step:Step.t -> 'a -> unit;
      right_up : 'a event; send_right_up : ?step:Step.t -> 'a -> unit; }

  let destroy evs = List.iter Ev.rem_cb evs.cbs

  let event_mouse_pos pt evs e =
    let r =
      ((Obj.magic evs.t) :> Dom_html.element Js.t) ## getBoundingClientRect in
    let x = (float (e ##. clientX)) -. r ##. left in
    let y = (float (e ##. clientY)) -. r ##. top in
    if not evs.normalize then pt x y else
    let nx = x /. (r ##. right -. r ##. left) in
    let ny = 1. -. (y /. (r ##. bottom -. r ##. top)) in
    pt nx ny

  let set_mouse_pos ~step evs e =
    let x, y as l = event_mouse_pos pt evs e in
    let epos = evs.pt x y in
    let dx = x -. fst evs.last_pos in
    let dy = y -. snd evs.last_pos in
    evs.send_dpos ~step (evs.pt dx dy);
    evs.set_pos ~step epos;
    evs.last_pos <- l;
    epos

  let move_cb evs _ e =
    let step = Step.create () in
    let _ = set_mouse_pos ~step evs e in
    Step.execute step;
    Ev.cb_ret ~propagate:evs.propagate ~default:evs.default e

  let mem_cb mem evs _ e =
    let step = Step.create () in
    let _ = set_mouse_pos ~step evs e in
    evs.set_mem ~step mem;
    Step.execute step;
    Ev.cb_ret ~propagate:evs.propagate ~default:evs.default e

  let down_cb evs _ e =
    let step = Step.create () in
    let epos = set_mouse_pos ~step evs e in
    let set, send_down = match Js.Optdef.to_option (e ##. which) with
    | Some Dom_html.Left_button -> evs.set_left, evs.send_left_down
    | Some Dom_html.Middle_button -> evs.set_mid, evs.send_mid_down
    | Some Dom_html.Right_button -> evs.set_right, evs.send_right_down
    | None | Some Dom_html.No_button ->
        warn_but(); evs.set_left, evs.send_left_down
    in
    set ~step true; send_down ~step epos;
    Step.execute step;
    Ev.cb_ret ~propagate:evs.propagate ~default:evs.default e

  let up_cb evs _ e =
    let step = Step.create () in
    let epos = set_mouse_pos ~step evs e in
    let set, send_up = match Js.Optdef.to_option (e ##. which) with
    | Some Dom_html.Left_button -> evs.set_left, evs.send_left_up
    | Some Dom_html.Middle_button -> evs.set_mid, evs.send_mid_up
    | Some Dom_html.Right_button -> evs.set_right, evs.send_right_up
    | None | Some Dom_html.No_button ->
        warn_but (); evs.set_left, evs.send_left_up
    in
    set ~step false; send_up ~step epos;
    Step.execute step;
    Ev.cb_ret ~propagate:evs.propagate ~default:evs.default e

  let doc_up_cb evs t e =
    (* [up_cb] will not fire if the mouse is no longer in the target;
        but this destroys the semantics of [left], [mid], [right].
        A callback attached to the document handles this. *)
    if not (S.rough_value evs.mem) &&
       (S.rough_value evs.left || S.rough_value evs.mid ||
        S.rough_value evs.right)
    then up_cb evs t e else
    Ev.cb_ret e

  let for_target
      ?(capture = false) ?(propagate = true) ?(default = propagate)
      ?(normalize = true) (t : 'a Ev.target) pt
    =
    let t = Obj.magic t in
    let pos, set_pos = S.create (pt 0. 0.) in
    let dpos, send_dpos = E.create () in
    let mem, set_mem = S.create false in
    let left, set_left = S.create false in
    let left_down, send_left_down = E.create () in
    let left_up, send_left_up = E.create () in
    let mid, set_mid = S.create false in
    let mid_down, send_mid_down = E.create () in
    let mid_up, send_mid_up = E.create () in
    let right, set_right = S.create false in
    let right_down, send_right_down = E.create () in
    let right_up, send_right_up = E.create () in
    let evs =
      { t; propagate; default; normalize; pt; last_pos = (0., 0.);
        cbs = [];
        pos; set_pos;
        dpos; send_dpos;
        mem; set_mem;
        left; set_left; left_down; send_left_down; left_up; send_left_up;
        mid; set_mid; mid_down; send_mid_down; mid_up; send_mid_up;
        right; set_right; right_down; send_right_down; right_up; send_right_up}
    in
    let cbs =
      [ Ev.(add_cb ~capture evs.t mousedown (down_cb evs));
        Ev.(add_cb ~capture evs.t mouseup (up_cb evs));
        Ev.(add_cb ~capture evs.t mousemove (move_cb evs));
        Ev.(add_cb ~capture evs.t mouseenter (mem_cb true evs));
        Ev.(add_cb ~capture evs.t mouseleave (mem_cb false evs));
        Ev.(add_cb Dom_html.document mouseup (doc_up_cb evs)) ]
    in
    evs.cbs <- cbs; evs

  let for_el ?capture ?propagate ?default ?normalize (`El t as e) pt =
    let evs = for_target ?capture ?propagate ?default ?normalize t pt in
    El.on_rem (fun () -> destroy evs) e;
    evs

  let pos evs = evs.pos
  let dpos evs = evs.dpos
  let mem evs = evs.mem
  let left evs = evs.left
  let left_down evs = evs.left_down
  let left_up evs = evs.left_up
  let mid evs = evs.mid
  let mid_down evs = evs.mid_down
  let mid_up evs = evs.mid_up
  let right evs = evs.right
  let right_down evs = evs.right_down
  let right_up evs = evs.right_up
end

module Human = struct
  let noticed = 0.1
  let interrupted = 1.
  let left = 10.

  let rec feel_action feel set_feel () =
    let new_feel, delay = match S.value feel with
    | `Interacting -> `Interrupted, left -. interrupted
    | `Interrupted -> `Left, 0.
    | `Left -> assert false
    in
    set_feel new_feel;
    if delay = 0. then () else
    let action = feel_action feel set_feel in
    let ms = delay *. 1000. in
    ignore (Dom_html.window ## setTimeout (Js.wrap_callback action) ms);
    ()

  let feel () =
    let feel, set_feel = S.create `Interacting in
    let action = feel_action feel set_feel in
    let ms = interrupted *. 1000. in
    ignore (Dom_html.window ## setTimeout (Js.wrap_callback action)  ms);
    feel

  (* Sizes in mm. *)
  let touch_target_size = 9.
  let touch_target_size_min = 7.
  let touch_target_pad = 2.
  let average_finger_width = 11.
end

module App = struct
  (* Environment *)

  let env key ~default parse =
    let args = match Url.Current.get () with
    | None -> []
    | Some (Url.Http u | Url.Https u) -> u.Url.hu_arguments
    | Some (Url.File u) -> u.Url.fu_arguments
    in
    try parse (List.assoc key args) with
    | _ -> default

  let quit, send_quit = E.create ()

  (* run *)

  let run ?name main =
    let main _ e = main (); Ev.cb_ret ~propagate:false e in
    let send_quit _ e = send_quit (); Ev.cb_ret ~propagate:false e in
    ignore (Ev.add_cb Dom_html.window Ev.unload send_quit);
    ignore (Ev.add_cb Dom_html.document Ev.domContentLoaded main);
    ()
end

(* Browser *)

module Win = struct
  type t = Dom_html.window Js.t

  let dow = Dom_html.window
  let device_pixel_ratio =
    if Js.Optdef.test ((Js.Unsafe.coerce Dom_html.window) ##. devicePixelRatio)
    then (fun () -> (Js.Unsafe.coerce Dom_html.window) ##. devicePixelRatio)
    else (fun () -> 1.0)
end

module Loc = struct

  (* Location URI *)

  let uri () = Dom_html.window ##. location ##. href
  let scheme () =
    let p = Dom_html.window ##. location ##. protocol in
    if p ##. length <> 0 then p ## slice 0 (-1) (* remove last ':' *) else p

  let host () = Dom_html.window ##. location ##. hostname
  let port () =
    let p = Dom_html.window ##. location ##. port in
    if p ##. length = 0 then None else
    let p = Str.to_string p in
    try Some (int_of_string p) with Failure _ -> None

  let query () =
    let q = Dom_html.window ##. location ##. search in
    if q ##. length = 0 then q else
    q ## slice_end (1) (* remove '?' *)

  let path () = Dom_html.window ##. location ##. pathname

  let fragment () =
    let f = Dom_html.window ##. location ##. hash in
    f
(*
    if f ##. length = 0 then f else
    f ## slice_end (1) (* remove '#' *)
*)

  let set_fragment frag = Dom_html.window ##. location ##. hash := frag

  let update ?scheme ?host ?port ?path ?query ?fragment () =
    let l = Dom_html.window ##. location in
    (match scheme with None -> () | Some s -> l ##. protocol := s);
    (match host with None -> () | Some h -> l ##. hostname := h);
    (match port with
     | None -> ()
     | Some p ->
         match p with
         | None -> ()
         | Some p -> l ##. port := (Js.string (string_of_int p)));
    (match path with None -> () | Some p -> l ##. pathname := p);
    (match query with None -> () | Some q -> l ##. search := q);
    (match fragment with None -> () | Some f -> l ##. hash := f);
    ()

  (* Location changes *)

  let hashchange =
    Ev.(for_target Dom_html.window hashchange (fun _ -> fragment ()))

  let set ?(replace = false) uri =
    if replace then Dom_html.window ##. location ## replace (uri) else
    Dom_html.window ##. location ## assign (uri)

  let reload () = (Dom_html.window ##. location) ## reload
end

module History = struct

  let history = Dom_html.window ##. history

  (* Moving in history *)

  let length () = history ##. length
  let go delta = history ## go (Js.some delta)
  let back () = history ## back
  let forward () = history ## forward

  (* History state *)

  type 'a state = str * 'a
  let create_state ~version s = (version, s)
  let state ~version ~default () =
    match Js.Opt.to_option (Obj.magic (history ##. state)) with
    | None -> default
    | Some (version', s) -> if version <> version' then default else s

  (* Making history *)

  let push ?(replace = false) ?state ~title uri =
    if replace
    then history ## replaceState (Js.Opt.option state) title (Js.some uri)
    else history ## pushState (Js.Opt.option state) title (Js.some uri)
end

module Info = struct
  let languages () =
    let langs =
      (Js.Unsafe.coerce (Dom_html.window ##. navigator)) ## languages
    in
    match Js.Optdef.to_option langs with
    | Some l -> array_to_list l
    | None ->
        match Js.Optdef.to_option (Dom_html.window ##. navigator ##. language)
        with
        | None -> [str "en"]
        | Some l -> [l]
end

module Store = struct

  type scope = [ `Session | `Persist ]

  let scope_store = function
  | `Session -> Js.Optdef.to_option (Dom_html.window ##. sessionStorage)
  | `Persist -> Js.Optdef.to_option (Dom_html.window ##. localStorage)

  let support scope = scope_store scope <> None

  type 'a key = Js.js_string Js.t

  let key_prefix = Js.string "k"
  let key =
    let id = ref (-1) in
    fun ?ns () ->
      id := !id + 1;
      let id = Js.string (string_of_int !id) in
      match ns with
      | None -> Str.append key_prefix id
      | Some ns -> Str.(append (append ns (str "-")) (append key_prefix id))

  let version = key ~ns:(str "brr") ()

  let mem ?(scope = `Persist) k = match scope_store scope with
  | Some s -> Js.Opt.test (s ## getItem (k))
  | None -> false

  let add ?(scope = `Persist) k v = match scope_store scope with
  | Some s -> s ## setItem k (Json.output v) | None -> ()

  let rem ?(scope = `Persist) k = match scope_store scope with
  | Some s -> s ## removeItem (k) | None -> ()

  let find ?(scope = `Persist) k = match scope_store scope with
  | None -> None
  | Some s ->
      begin match Js.Opt.to_option (s ## getItem (k)) with
      | None -> None
      | Some vs -> Some (Json.unsafe_input vs)
      end

  let get ?(scope = `Persist) ?absent k = match scope_store scope with
  | None -> invalid_arg "store unsupported"
  | Some s ->
      begin match Js.Opt.to_option (s ## getItem (k)) with
      | None ->
          begin match absent with
          | None -> invalid_arg "key unbound"
          | Some v -> v
          end
      | Some vs -> Json.unsafe_input vs
      end

  let force_version ?(scope = `Persist) v = match scope_store scope with
  | None -> ()
  | Some s ->
      match find ~scope version with
      | None -> add ~scope version v
      | Some sv -> if v <> sv then (s ## clear; add ~scope version v)

  let clear ?(scope = `Persist) () = match scope_store scope with
  | Some s -> s ## clear | None -> ()
end

(*---------------------------------------------------------------------------
   Copyright (c) 2018 The brr programmers

   Permission to use, copy, modify, and/or distribute this software for any
   purpose with or without fee is hereby granted, provided that the above
   copyright notice and this permission notice appear in all copies.

   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
   ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
   ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
   OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
  ---------------------------------------------------------------------------*)
