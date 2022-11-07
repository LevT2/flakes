{
  inputs = {
    nixpkgs_.url = "github:br4ch1st0chr0n3/flakes?dir=source-flake/nixpkgs";
    flake-utils_.url = "github:br4ch1st0chr0n3/flakes?dir=source-flake/flake-utils";
    nixpkgs.follows = "nixpkgs_/nixpkgs";
    flake-utils.follows = "flake-utils_/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }: flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (pkgs.lib.attrsets) recursiveUpdate;
      inherit (builtins) foldl' attrValues mapAttrs attrNames readDir map;
      inherit (pkgs.lib.strings) concatStringsSep concatMapStringsSep;
      # if a set's attribute values are all sets, merge these values recursively
      # Note that the precedence order is undefined, so it's better to 
      # have unique values at each set level
      # Examples:
      # mergeValues {a = {b = 1;}; c = {d = 2;};} => {b = 1; d = 2;}
      mergeValues = set@{ ... }:
        foldl' recursiveUpdate { } (attrValues set);

      # a convenience function that flattens a set with set attribute values
      # toList {a = {b = 1;}; c = {d = 2;};} => [1 2]
      toList = x: attrValues (mergeValues x);

      # make shell apps
      # arg should be a set of sets of inputs
      mkShellApps = appsInputs@{ ... }: mapAttrs (name: value: mkShellApp (value // { inherit name; })) appsInputs;


      # has a runtime dependency on fish!
      fishHook = { hook ? "", shellName, fish, }:
        let
          # Name of a variable that accumulates shell names
          MY_SHELL_NAME = "MY_SHELL_NAME";
        in
        ''
          ${hook}

          ${fish.pname} -C '
            set ${MY_SHELL_NAME} ${shellName}

            source ${./scripts/devshells.fish};
          ' -i;
        '';

      runFishScript = { name, fishScriptPath, runtimeInputs ? [ ], text ? "" }: mkShellApp {
        inherit name;
        runtimeInputs = runtimeInputs ++ [ pkgs.fish pkgs.jq ];
        text =
          let CURRENT_SYSTEM = "CURRENT_SYSTEM"; in
          ''
            export CURRENT_SYSTEM=${system}
            
            ${text}

            fish ${fishScriptPath}
          '';
        longDescription = ''
          run a `fish` [script](${fishScriptPath})
        '';
      };


      # create devshells
      # notice the dependency on fish
      mkDevShellsWithFish = shells@{ ... }: { fish }:
        mapAttrs
          (shellName: shellAttrs:
            let buildInputs = pkgs.lib.lists.flatten ((shellAttrs.buildInputs or [ ]));
              inherit (pkgs.lib.strings) concatStringsSep concatMapStringsSep;
            in
            withLongDescription
              (pkgs.mkShell (shellAttrs // {
                inherit shellName;
                buildInputs = buildInputs ++ [ fish desc ];
                # We need to exit the shell in which fish runs
                # Otherwise, after a user exits fish, she will return to a default shell
                shellHook = ''
                  ${fishHook {
                    inherit shellName fish;
                    hook = shellAttrs.shellHook or "";
                  }}
                  exit
                '';
              }))
              ''
                A devshell `${shellName}` with `fish`

                The entries from `/bin`-s of other `buildInputs` are:
                ${
                  concatMapStringsSep "\n"
                    (x: "- " + 
                      (concatMapStringsSep ", " (s: "`${s}`") (
                        attrNames  (
                          pkgs.lib.attrsets.filterAttrs
                            (name: value: value == "regular")
                            (readDir "${x}/bin")
                        )
                      )
                    ))
                  buildInputs
                }
              ''
          )
          shells;

      # make shells
      # The default devshell should be the system's shell
      # If start another shell in a shell hook, direnv will loop infinitely
      # Other shells will start a `fish` shell
      mkDevShellsWithDefault =
        defaultShellAttrs@{ buildInputs ? [ ], shellHook ? "", ... }:
        shells@{ ... }:
        let
          shells_ = mkDevShellsWithFish shells { inherit (pkgs) fish; };
          default = pkgs.mkShell (defaultShellAttrs // {
            name = "default";
            buildInputs = buildInputs ++ [ desc ];
            shellHook = ''
              ${shellHook}
            '';
          });
          devShells_ = shells_ // { inherit default; };
        in
        devShells_;

      # read something in a directory using the builtin function
      readXs = dir: type: attrNames (
        pkgs.lib.attrsets.filterAttrs (name_: type_: type_ == type) (readDir dir)
      );

      readFiles = dir: readXs dir "regular";
      readDirectories = dir: readXs dir "directory";
      readSymlinks = dir: readXs dir "symlink";

      # assuming that a `name` of a program coincides with its main executable's name
      mkBin = drv@{ name, ... }: "${drv}/bin/${name}";

      # same as mkBin, but need to provide the necessary executable name
      mkBinName = drv@{ name, ... }: name_: "${drv}/bin/${name_}";

      # frame a text with newlines
      framedNewlines = framed_ "\n\n" "\n\n";
      framed_ = pref: suff: txt: ''${pref}${txt}${suff}'';

      # frame a text with square brackets and newlines
      framedBrackets = framedBrackets_ "\n\n" "\n\n";
      framedBrackets_ = pref: suff: framed_ "${pref}[ " " ]${suff}";

      # concat strings and separate them by a newline character
      concatStringsNewline = concatStringsSep "\n";

      # concatMap strings and separate them by a newline character
      concatMapStringsNewline = concatMapStringsSep "\n";

      # ignore shellcheck when writing a shell application
      mkShellApp = args@{ name, text, runtimeInputs ? [ ], longDescription ? "", description ? "" }:
        (pkgs.lib.meta.addMetaAttrs
          { inherit longDescription description; }
          (
            pkgs.writeShellApplication ({ inherit name text; } // {
              runtimeInputs = pkgs.lib.lists.flatten (args.runtimeInputs or [ ]);
              checkPhase = "";
            })));

      withAttrs = drv: attrSet: pkgs.lib.attrsets.recursiveUpdate drv attrSet;
      withMeta = drv: meta: withAttrs drv { inherit meta; };
      withLongDescription = drv: longDescription: withAttrs drv { meta = { inherit longDescription; }; };


      # String -> String -> Set -> IO ()
      writeJSON = name: path: dataNix:
        let
          dataJSON = builtins.toJSON dataNix;
          name_ = "write-${name}-json";
          dir = builtins.dirOf path;
          file = builtins.baseNameOf path;
        in
        mkShellApp {
          name = name_;
          runtimeInputs = [ pkgs.python310 ];
          text = ''
            mkdir -p ${dir}
            printf "%s" ${
              pkgs.lib.escapeShellArg dataJSON
            } | python -m json.tool > ${path}
            printf "${framedBrackets "ok %s"}" "${name_}"
          '';
          longDescription = ''write a given `Nix` expression as `JSON` into `path`'';
        };

      # use when need to generate settings.json etc.
      json2nix = mkShellApp {
        name = "json2nix";
        runtimeInputs = [ pkgs.nixpkgs-fmt ];
        text = ''
          json_path=$1
          nix_path=$2
          nix eval --impure --expr "with builtins; fromJSON (readFile ./$json_path)" > $nix_path
          sed -i -E "s/(\[|\{)/\1\n/g" $nix_path
          nixpkgs-fmt $nix_path
        '';
        longDescription = ''
          Convert a `.json` into `.nix` at runtime. No need to provide the full path to a file if it's in the `CWD`. 
          
          Example:

            ```sh
            json2nix .vscode/settings.json my-settings.nix
            ```
        '';
      };

      # TODO override mkShellApp to install the longDescription into a $out/share directory
      # and read the description from there
      desc = mkShellApp (
        let command = ''nix eval --raw "$1.meta.longDescription"''; in
        {
          name = "desc";
          text =
            ''
              description=$(${command})

              printf "\n\n$description\n\n" | glow -
            '';
          runtimeInputs = [ pkgs.glow ];
          longDescription = ''
            Show the description of a derivation (`meta.longDescription` or `meta.description`) as 
            [glow](https://github.com/charmbracelet/glow) - rendered Markdown.

            Runs `${command}` with your argument as `$1`
          '';
        }
      );

      runInEachDir = args@{ dirs, command, name, preMessage ? "", message ? "", postMessage ? "", runtimeInputs ? [ ], longDescription ? "" }:
        (mkShellApp {
          name = "${name}-in-each-dir";
          inherit runtimeInputs;
          text =
            let INITIAL_CWD = "INITIAL_CWD";
            in
            ''
              ${INITIAL_CWD}=$PWD
              printf "%s" '${preMessage}'

            '' +
            builtins.concatStringsSep "\n"
              (map
                (dir: ''
                  printf "${framedBrackets "${if message == "" then name else message} : %s"}" "${"$" + INITIAL_CWD}/${dir}"

                  cd ${"$" + INITIAL_CWD}/${dir}
            
                  ${command}
                '')
                (pkgs.lib.lists.flatten dirs)) +
            ''
              printf "%s" '${postMessage}'
            '';
          longDescription = ''
            ${longDescription}
            
            The directories relative to $PWD are:

              ```sh
              ${concatStringsNewline dirs}
              ```
          '';
        });

      # apply an `op` `cnt` times to the initial value `ini` to get `res`
      # initially, `res` = `ini`
      applyN = cnt: op: res: (if cnt > 0 then applyN (cnt - 1) op (op res) else res);
    in
    {
      packages = {
        inherit
          desc
          json2nix
          ;
      };
      functions = {
        inherit
          applyN
          fishHook
          framed_
          framedBrackets
          framedBrackets_
          framedNewlines
          mergeValues
          mkBin
          mkBinName
          mkDevShellsWithDefault
          mkDevShellsWithFish
          mkShellApp
          mkShellApps
          concatMapStringsNewline
          concatStringsNewline
          readDirectories
          readFiles
          readSymlinks
          readXs
          runFishScript
          runInEachDir
          toList
          withAttrs
          withLongDescription
          withMeta
          writeJSON
          ;
      };

      # tests 
      devShells = mkDevShellsWithDefault
        {
          buildInputs = [ pkgs.tree json2nix desc ];
        }
        {
          fish = { };
        };
      tests = {
        t = readFiles ./.;
      };
    });
}
