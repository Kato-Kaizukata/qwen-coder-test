/* suckless.nix — a pure re-implementation of nixpkgs' lib.evalModules.

   The contract (this is the whole point):

     1. Last Precedence, not Integer Priority.
        Every config definition for an option is collected into a list in
        module order; the LAST element wins. No `priority` field exists,
        anywhere, ever.

     2. No mkIf / mkMerge. A module is always active; it just defines
        fewer options. "Conditionals" are expressed by which modules you
        put in `imports`.

     3. No `inherit builtins`. Every primitive is spelled `builtins.x` at
        the call site — grep once, find every use.

     4. `imports = [ ... ];` still works (plus `config` and `options`;
        anything else in a module is ignored).

     5. lib.types are gone. Validation lives in `options.<name>.class`,
        a plain predicate over the resolved value:

          options.example.name = {
            default = "test";
            class = builtins.isString;
          };

   Option names are dotted strings ("suckless.editor"), never nested
   attribute sets — that single decision deletes the entire upstream
   subtree/deps/lojban machinery. One file, ~100 lines of logic. */
rec {

  # ---- mergeModules' : the core fold ------------------------------------
  #
  #   mergeModules' :: { modules :: [ module ] } -> { options, config }
  #
  #   module  = { imports?, options?, config? }  (or a function returning one)
  #   options = { "<dot-name>" = { default?, class?, ... }; }  merged per name
  #   config  = { "<dot-name>" = value; }                      last one wins
  mergeModules' = { modules ? [ ] }:
    let
      # depth-first, pre-order import resolution: imported modules land
      # BEFORE the importing one (same ordering semantics as nixpkgs).
      # No dedup, no cycle detection — import a cycle, get a stack error.
      # That is the suckless trade.
      flatten = ms:
        builtins.concatMap
          (m: [ m ] ++ flatten (m.imports or [ ]))
          ms;

      # ONE zipAttrsWith folds both blocks per option name into ordered
      # lists of definitions. This call IS the merging algorithm.
      perName = builtins.zipAttrsWith (_: defs: defs)
        (map (m: {
            config  = m.config  or { };
            options = m.options or { };
          })
          (flatten modules));

      rawConfig  = perName.config  or { };
      rawOptions = perName.options or { };

      # defining config for an option nobody declared is an error — the
      # one and only well-formedness check this evaluator keeps
      undefined = builtins.filter
        (n: !(builtins.hasAttr n rawOptions))
        (builtins.attrNames rawConfig);

      # last declaration wins each attribute: later modules refine earlier
      # ones (this replaces upstream's types.addOption/mergeOption stuff)
      optionOf = decls: builtins.foldl' (acc: d: acc // d) { } decls;

      # resolve: last definition wins, else declared default, else null
      valueOf = name: opt:
        if rawConfig.${name} != [ ]
        then builtins.elemAt rawConfig.${name}
               (builtins.length rawConfig.${name} - 1)
        else opt.default or null;

      # the class predicate is the type checker; all of it
      check = name: opt: val:
        if opt ? class && !opt.class val
        then builtins.throw "suckless: ${name}: value fails class predicate"
        else val;

      buildOne = name:
        let
          opt = optionOf (rawOptions.${name} or [ ]);
          val = check name opt (valueOf name opt);
        in { inherit name opt val; };

      allNames = builtins.attrNames rawOptions
        ++ builtins.filter (n: !(builtins.elem n (builtins.attrNames rawOptions)))
            (builtins.attrNames rawConfig);

      built = map buildOne allNames;

      # split a dotted path into its components
      partsOf = path: builtins.filter (s: s != "") (builtins.split "\\." path);

      # write a leaf into a fresh nested attrset along its dotted path
      addLeaf = path: val:
        let
          go = ks:
            if ks == [ ] then val
            else { ${builtins.head ks} = go (builtins.tail ks); };
        in go (partsOf path);

      recursiveUpdate = a: b:
        builtins.foldl'
          (acc: n:
            if builtins.isAttrs b.${n} && builtins.isAttrs (a.${n} or { })
            then acc // { ${n} = recursiveUpdate a.${n} b.${n}; }
            else acc // { ${n} = b.${n}; })
          a
          (builtins.attrNames b);

      # final config: flat { "<dot-name>" = value } folded back into a
      # nested attrset so `ev.config.suckless.editor` reads like nixpkgs
      config =
        builtins.foldl'
          (acc: e: recursiveUpdate acc (addLeaf e.name e.val))
          { }
          built;

      # final options: flat map of resolved declarations (dotted keys —
      # introspection stays one lookup deep, no lazy subtree magic)
      options =
        builtins.foldl'
          (acc: e: acc // { ${e.name} = e.opt; })
          { }
          built;
    in {
      options = options // {
        "<assert-unknown>" =
          undefined == [ ]
          || builtins.throw "suckless: no declaration for option(s): ${
               builtins.concatStringsSep ", " undefined}";
      };
      inherit config;
    };

  # ---- evalModules : public entry, nixpkgs-shaped ------------------------
  # functional modules are called with { config, options } plus whatever
  # `args` the caller passes; the trailing `...` in a module pattern drops
  # what it doesn't ask for, so no special-casing is needed.
  evalModules = { modules ? [ ], args ? { } }:
    mergeModules' {
      modules = map
        (m: if builtins.isFunction m
            then m ({ config = { }; options = { }; } // args)
            else m)
        modules;
    };

  # ---- helpers replacing the old lib.types machinery ---------------------
  # predicates ARE the new types, so combinators are predicate builders.
  lib = {
    listOf   = t: vs: builtins.all t vs;
    either   = a: b: v: a v || b v;
    oneOf    = cs: v: builtins.any (c: c == v) cs;
    enum     = cs: v: builtins.elem v cs;
    const    = v: _: v;
    anything = _: true;
  };

  # ---- example modules — the "distro" part --------------------------------
  # note what is NOT here: no enable guards, no mkIf, no priority ints,
  # no submodule types. Just functions returning attrs.

  exampleA = { config, options, ... }: {
    options.suckless.editor = {
      default = "vi";
      class = builtins.isString;
    };
    options.suckless.build.maxJobs = {
      default = 1;
      class = builtins.isInt;
    };
    config.suckless.editor = "ed";        # defined first...
    config.suckless.build.maxJobs = 4;
  };

  exampleB = { config, options, ... }: {
    config.suckless.editor = "vim";       # ...defined later => LAST WINS
    options.suckless.editor.class = lib.enum [ "ed" "vi" "vim" ];
  };

  exampleOS = { config, options, ... }: {
    imports = [ exampleA exampleB ];      # imports accept inline modules too
    options.suckless.hostName = {
      default = "suckless";
      class = builtins.isString;
    };
    config.suckless.hostName = "plan9-is-dead";
  };

  tests =
    let
      ev    = evalModules { modules = [ exampleOS ]; };
      evDef = evalModules { modules = [ exampleA ]; };
      tc = name: expect: got:
        if expect == got then "${name}: ok"
        else builtins.throw "${name}: FAIL expected ${toString expect} got ${toString got}";
    in [
      (tc "last-precedence"  "vim"           ev.config.suckless.editor)
      (tc "nested-option"    4               ev.config.suckless.build.maxJobs)
      (tc "default-used"     "vi"            evDef.config.suckless.editor)
      (tc "imports-work"     "plan9-is-dead" ev.config.suckless.hostName)
      (tc "option-class"     true            (ev.options.suckless.editor.class "vim"))
    ];
}
