# Build homesync-server from backend/uv.lock (wheels). Dev shells stay uv/.venv.
{
	lib,
	pkgs,
	python3,
	workspace,
	pyproject-nix,
	pyproject-build-systems,
	pyprojectOverlay,
}:
let
	python = python3;
	backendRoot = ../backend;
	pythonSet = (pkgs.callPackage pyproject-nix.build.packages {
		inherit python;
	}).overrideScope (
		lib.composeManyExtensions [
			pyproject-build-systems.overlays.wheel
			pyprojectOverlay
			(_final: prev: {
				homesync-server = prev.homesync-server.overrideAttrs (_old: {
					src = lib.fileset.toSource {
						root = backendRoot;
						fileset = lib.fileset.unions [
							(backendRoot + "/pyproject.toml")
							(backendRoot + "/src")
						];
					};
				});
			})
		]
	);
	venv = pythonSet.mkVirtualEnv "homesync-server-env" workspace.deps.default;
	bins = [
		"homesync"
		"homesync-server"
		"homesync-index"
		"homesync-gc"
		"homesync-migrate-data"
	];
in
	pkgs.runCommand "homesync-server" {
		meta = {
			description = "Homesync catalog daemon";
			mainProgram = "homesync-server";
		};
	} ''
		mkdir -p $out/bin
		${lib.concatMapStringsSep "\n" (b: ''
			ln -s ${lib.escapeShellArg "${venv}/bin/${b}"} $out/bin/${b}
		'') bins}
	''
