(* Excerpt of Frama-C's share/analysis-scripts/list_functions.ml (33.0 and
   34.0~beta), enough for lib/patch_sources.py: a plug-in Self and the
   unconditional entry point at the end.  LGPL-2.1, CEA. *)
module Self = Plugin.Register
    (struct
      let name = "List-functions"
      let shortname = "list-functions"
      let help = "prints the list of function definitions and declarations, \
                  along with their locations and number of statements, \
                  in text or JSON format"
    end)

let run () = ()

let () = Boot.Main.extend run
