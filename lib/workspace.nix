{
  lib,
  pyproject-nix,
  lock1,
  build,
  ...
}:

let
  inherit (lib)
    importTOML
    splitString
    length
    elemAt
    filter
    attrsToList
    match
    replaceStrings
    concatMap
    optional
    any
    fix
    mapAttrs
    attrNames
    all
    unique
    foldl'
    isPath
    isAttrs
    attrValues
    assertMsg
    isFunction
    nameValuePair
    listToAttrs
    pathExists
    removePrefix
    groupBy
    head
    isString
    ;
  inherit (builtins) readDir hasContext;
  inherit (pyproject-nix.lib.project) loadUVPyproject; # Note: Maybe we want a loader that will just "remap-all-the-things" into standard attributes?
  inherit (pyproject-nix.lib) pep440 pep508;

  # Match str against a glob pattern
  globMatches =
    let
      mkRe = replaceStrings [ "*" ] [ ".*" ]; # Make regex from glob pattern
    in
    glob:
    let
      re = mkRe glob;
    in
    s: match re s != null;

  splitPath = splitString "/";

in

fix (self: {
  /**
    Load a workspace from a workspace root

    # Arguments

    `workspaceRoot`: Workspace root as a path

    `config`: Config overrides for settings automatically inferred by `loadConfig`

      Can be passed as either:
      - An attribute set
      - A function taking the generated config as an argument, and returning the augmented config

    ## Workspace attributes
    - `mkPyprojectOverlay`: Create an overlay for usage with pyproject.nix's builders
    - `mkPyprojectEditableOverlay`: Generate an overlay to use with pyproject.nix's build infrastructure to install dependencies in editable mode.
    - `config`: Workspace config as loaded by `loadConfig`
    - `deps`: Pre-defined dependency declarations for top-level workspace packages
      - `default`: No optional-dependencies or dependency-groups enabled
      - `optionals`: All optional-dependencies enabled
      - `groups`: All dependency-groups enabled
      - `all`: All optional-dependencies & dependency-groups enabled
  */
  loadWorkspace =
    {
      # Workspace root as a path
      workspaceRoot,
      # Config overrides for settings automatically inferred by loadConfig
      # Can be passed as either:
      # - An attribute set
      # - A function taking the generated config as an argument, and returning the augmented config
      config ? { },
    }:
    assert (isPath workspaceRoot || (isString workspaceRoot || hasContext workspaceRoot));
    assert isAttrs config || isFunction config;
    let
      pyproject = importTOML (workspaceRoot + "/pyproject.toml");
      uvLock = lock1.parseLock (importTOML (workspaceRoot + "/uv.lock"));

      localPackages = filter lock1.isLocalPackage uvLock.package;

      workspaceProjects = listToAttrs (
        map (
          package:
          nameValuePair package.name (loadUVPyproject {
            projectRoot =
              let
                localPath = lock1.getLocalPath package;
              in
              if localPath == "." then workspaceRoot else workspaceRoot + "/${localPath}";
          })
        ) localPackages
      );

      # Load supported tool.uv settings
      loadedConfig = self.loadConfig (
        # Extract pyproject.toml from loaded projects
        (map (project: project.pyproject) (attrValues workspaceProjects))
        # If workspace root is a virtual root it wasn't discovered as a member directory
        # but config should also be loaded from a virtual root
        ++ optional (!(pyproject ? project)) pyproject
      );

      # Merge with overriden config
      config' = loadedConfig // (if isFunction config then config loadedConfig else config);

      # Set default sourcePreference
      defaultSourcePreference =
        if config'.no-binary then
          "sdist"
        else if config'.no-build then
          "wheel"
        else
          throw "No sourcePreference was passed, and could not be automatically inferred from workspace config";

      mkOverlay' =
        {
          sourcePreference,
          environ,
          spec,
        }:
        final: prev:
        let
          inherit (final) callPackage;

          # Note: Using Python from final here causes infinite recursion.
          # There is no correct way to override the python interpreter from within the set anyway,
          # so all facts that we get from the interpreter derivation are still the same.
          environ' = pep508.setEnviron (pep508.mkEnviron prev.python) environ;
          pythonVersion = environ'.python_full_version.value;

          resolved = lock1.resolveDependencies {
            lock = lock1.filterConflicts {
              lock = uvLock;
              inherit spec;
            };
            environ = environ';
            dependencies = attrNames spec;
          };

          buildRemotePackage = build.remote {
            inherit workspaceRoot;
            config = config';
            defaultSourcePreference = sourcePreference;
          };

        in
        # Assert that requires-python from uv.lock is compatible with this interpreter
        assert all (spec: pep440.comparators.${spec.op} pythonVersion spec.version) uvLock.requires-python;
        # Assert that supported-environments is compatible with this environment
        assert all (marker: pep508.evalMarkers environ' marker) (attrValues uvLock.supported-markers);
        mapAttrs (
          name: package:
          # Call different builder functions depending on if package is local or remote (pypi)
          if workspaceProjects ? ${name} then
            callPackage (build.local {
              environ = environ';
              localProject = workspaceProjects.${name};
              inherit package;
            }) { }
          else
            callPackage (buildRemotePackage package) { }
        ) resolved;

    in
    assert assertMsg (
      !(config'.no-binary && config'.no-build)
    ) "Both tool.uv.no-build and tool.uv.no-binary are set to true, making the workspace unbuildable";
    rec {
      /*
        Workspace config as loaded by loadConfig
        .
      */
      config = config';

      /*
        Generate an overlay to use with pyproject.nix's build infrastructure.

        See https://pyproject-nix.github.io/pyproject.nix/lib/build.html
      */
      mkPyprojectOverlay =
        {
          # Whether to prefer sources from either:
          # - wheel
          # - sdist
          #
          # See FAQ for more information.
          sourcePreference ? defaultSourcePreference,
          # PEP-508 environment customisations.
          # Example: { platform_release = "5.10.65"; }
          environ ? { },
          # Dependency specification used for conflict resolution.
          # By default mkPyprojectOverlay resolves the entire workspace, but that will not work for resolutions with conflicts.
          dependencies ? deps.all,
        }:
        let
          overlay = mkOverlay' {
            inherit sourcePreference environ;
            spec = dependencies;
          };
          crossOverlay = lib.composeExtensions (_final: prev: {
            pythonPkgsBuildHost = prev.pythonPkgsBuildHost.overrideScope overlay;
          }) overlay;
        in
        final: prev:
        let
          inherit (prev) stdenv;
        in
        # When doing native compilation pyproject.nix aliases pythonPkgsBuildHost to pythonPkgsHostHost
        # for performance reasons.
        #
        # Mirror this behaviour by overriding both sets when cross compiling, but only override the
        # build host when doing native compilation.
        if stdenv.buildPlatform != stdenv.hostPlatform then crossOverlay final prev else overlay final prev;

      /*
        Generate an overlay to use with pyproject.nix's build infrastructure to install dependencies in editable mode.
        Note: Editable support is still under development and this API might change.

        See https://pyproject-nix.github.io/pyproject.nix/lib/build.html
      */
      mkEditablePyprojectOverlay =
        {
          # Editable root as a string.
          root ? (toString workspaceRoot),
          # Workspace members to make editable as a list of strings. Defaults to all local projects.
          members ? map (package: package.name) localPackages,
        }:
        assert assertMsg (!lib.hasPrefix builtins.storeDir root) ''
          Editable root was passed as a Nix store path.

          ${lib.optionalString lib.inPureEvalMode ''
            This is most likely because you are using Flakes, and are automatically inferring the editable root from workspaceRoot.
            Flakes are copied to the Nix store on evaluation. This can temporarily be worked around using --impure.
          ''}
          Pass editable root either as a string pointing to an absolute non-store path, or use environment variables for relative paths.
        '';
        _final: prev:
        let
          # Filter any local packages that might be deactivated by markers or other filtration mechanisms.
          activeMembers = filter (name: !prev ? name) members;
        in
        listToAttrs (
          map (
            name:
            nameValuePair name (
              prev.${name}.override {
                # Prefer src layout if available
                editableRoot =
                  let
                    inherit (workspaceProjects.${name}) projectRoot;
                  in
                  root
                  + (removePrefix (toString workspaceRoot) (
                    toString (if pathExists (projectRoot + "/src") then (projectRoot + "/src") else projectRoot)
                  ));
              }
            )
          ) activeMembers
        );

      # Pre-defined dependency specifications.
      deps =
        let
          # Extract dependency groups/optional-dependencies from all local projects
          # operating under the assumptions that a local project only has one possible resolution
          # and that no local projects are filtered out by markers
          packages' =
            mapAttrs
              (
                _name: packages:
                assert length packages == 1;
                head packages
              )
              (
                groupBy (package: package.name)
                  # Don't include local packages pulled in to the workspace from a directory specification.
                  # These might be local, but are not considered as a part of the workspace
                  (filter (package: !package.source ? directory) localPackages)
              );
        in
        {
          # Dependency specification with all optional dependencies & groups
          all = mapAttrs (
            _: package: unique (attrNames package.optional-dependencies ++ attrNames package.dev-dependencies)
          ) packages';

          # Dependency specifications with will all optional dependencies
          optionals = mapAttrs (_: package: attrNames package.optional-dependencies) packages';

          # Dependency specifications with will all groups
          groups = mapAttrs (_: package: attrNames package.dev-dependencies) packages';

          # Dependency specification with default dependencies
          default = mapAttrs (
            name: _: workspaceProjects.${name}.pyproject.tool.uv.default-groups or [ ]
          ) packages';
        };
    };

  /**
    Load supported configuration from workspace

    Supports:
    - tool.uv.no-binary
    - tool.uv.no-build
    - tool.uv.no-binary-packages
    - tool.uv.no-build-packages
  */
  loadConfig =
    # List of imported (lib.importTOML) pyproject.toml files from workspace from which to load config
    pyprojects:
    let
      no-build' = foldl' (
        acc: pyproject:
        (
          if pyproject ? tool.uv.no-build then
            (
              if acc != null && pyproject.tool.uv.no-build != acc then
                (throw "Got conflicting values for tool.uv.no-build")
              else
                pyproject.tool.uv.no-build
            )
          else
            acc
        )
      ) null pyprojects;

      no-binary' = foldl' (
        acc: pyproject:
        (
          if pyproject ? tool.uv.no-binary then
            (
              if acc != null && pyproject.tool.uv.no-binary != acc then
                (throw "Got conflicting values for tool.uv.no-binary")
              else
                pyproject.tool.uv.no-binary
            )
          else
            acc
        )
      ) null pyprojects;
    in
    {
      no-build = if no-build' != null then no-build' else false;
      no-binary = if no-binary' != null then no-binary' else false;
      no-binary-package = unique (
        concatMap (pyproject: pyproject.tool.uv.no-binary-package or [ ]) pyprojects
      );
      no-build-package = unique (
        concatMap (pyproject: pyproject.tool.uv.no-build-package or [ ]) pyprojects
      );
    };

  /*
    Discover workspace member directories from a workspace root.
    Returns a list of strings relative to the workspace root.
  */
  discoverWorkspace =
    {
      # Workspace root directory
      workspaceRoot,
      # Workspace top-level pyproject.toml
      pyproject ? importTOML (workspaceRoot + "/pyproject.toml"),
    }:
    let
      workspace' = pyproject.tool.uv.workspace or { };
      excluded = map (g: globMatches "/${g}") (workspace'.exclude or [ ]);
      globs = map splitPath (workspace'.members or [ ]);

    in
    # Get a list of workspace member directories
    filter (x: length excluded == 0 || any (e: !e x) excluded) (
      concatMap (
        glob:
        let
          max = (length glob) - 1;
          recurse =
            rel: i:
            let
              dir = workspaceRoot + "/${rel}";
              dirs = map (e: e.name) (filter (e: e.value == "directory") (attrsToList (readDir dir)));
              matches = filter (globMatches (elemAt glob i)) dirs;
            in
            if i == max then
              map (child: rel + "/${child}") matches
            else
              concatMap (child: recurse (rel + "/${child}") (i + 1)) matches;
        in
        recurse "" 0
      ) globs
    )
    # If the package is a virtual root we don't add the workspace root to project discovery
    ++ optional (pyproject ? project) "/";

})
