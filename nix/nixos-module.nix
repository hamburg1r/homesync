self:
{
	config,
	lib,
	pkgs,
	...
}:
let
	cfg = config.services.homesync;
	inherit (lib)
		concatMapStringsSep
		escapeShellArg
		getExe'
		mkEnableOption
		mkIf
		mkMerge
		mkOption
		types
		;
	readPaths = lib.unique (cfg.extraReadPaths ++ cfg.indexRoots);
	defaultPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.homesync-server;
	envAttrs = {
		HOMESYNC_DATA = cfg.dataDir;
		HOMESYNC_HOST = cfg.host;
		HOMESYNC_PORT = toString cfg.port;
		HOMESYNC_RELOAD = "0";
		HOMESYNC_KDBX_SECRETS = cfg.kdbxSecretsPath;
		HOMESYNC_CONFIG = cfg.configPath;
	} // cfg.extraEnvironment;
	commonServiceConfig = {
		User = cfg.user;
		Group = cfg.group;
		WorkingDirectory = cfg.dataDir;
		ProtectSystem = "strict";
		ProtectHome = cfg.protectHome;
		PrivateTmp = true;
		NoNewPrivileges = true;
		RestrictSUIDSGID = true;
		LockPersonality = true;
		RestrictRealtime = true;
		ProtectKernelModules = true;
		ProtectKernelTunables = true;
		ProtectControlGroups = true;
		RestrictAddressFamilies = [
			"AF_INET"
			"AF_INET6"
			"AF_UNIX"
		];
		SystemCallArchitectures = "native";
		ReadWritePaths = [ cfg.dataDir ];
		BindPaths = [ cfg.dataDir ];
		UMask = "0027";
	} // lib.optionalAttrs (readPaths != [ ]) {
		BindReadOnlyPaths = readPaths;
	};
in
{
	options.services.homesync = {
		enable = mkEnableOption "Homesync catalog daemon";

		package = mkOption {
			type = types.package;
			default = defaultPackage;
			defaultText = lib.literalExpression "homesync.packages.\${system}.homesync-server";
			description = "Homesync package providing homesync-server and CLI tools.";
		};

		user = mkOption {
			type = types.str;
			default = "homesync";
			description = "User the daemon runs as.";
		};

		group = mkOption {
			type = types.str;
			default = "homesync";
			description = "Group the daemon runs as.";
		};

		createUser = mkOption {
			type = types.bool;
			default = true;
			description = "Create the system user and group. Set false when using an existing login user.";
		};

		dataDir = mkOption {
			type = types.str;
			default = "/var/lib/homesync";
			description = "Managed store (catalog.sqlite, blobs/, thumbs/, quarantine/). Sets HOMESYNC_DATA.";
		};

		configPath = mkOption {
			type = types.str;
			default = "/var/lib/homesync/config.toml";
			description = "HOMESYNC_CONFIG path (optional TOML; data_dir is overridden by HOMESYNC_DATA).";
		};

		kdbxSecretsPath = mkOption {
			type = types.str;
			default = "/var/lib/homesync/kdbx_secrets.json";
			description = "KeePass unlock secrets JSON (mode 0600; not in catalog SQLite).";
		};

		host = mkOption {
			type = types.str;
			default = "127.0.0.1";
			description = ''
				Bind address. Default is localhost. For phone/LAN use a Tailscale IP or 0.0.0.0
				only on a trusted network — v1 has no auth.
			'';
		};

		port = mkOption {
			type = types.port;
			default = 8787;
			description = "HTTP port.";
		};

		openFirewall = mkOption {
			type = types.bool;
			default = false;
			description = "Open TCP port in the NixOS firewall. Keep false unless the bind is VPN/LAN-only.";
		};

		protectHome = mkOption {
			type = types.bool;
			default = true;
			description = ''
				systemd ProtectHome. Hash-in-place library roots under /home need extraReadPaths
				or protectHome = false.
			'';
		};

		extraReadPaths = mkOption {
			type = types.listOf types.str;
			default = [ ];
			example = [ "/home/you/Pictures" ];
			description = "Additional read-only paths (library roots for hash-in-place blob GET). indexRoots are included automatically.";
		};

		extraEnvironment = mkOption {
			type = types.attrsOf types.str;
			default = { };
			description = "Extra environment variables for the daemon and index unit.";
		};

		indexRoots = mkOption {
			type = types.listOf types.str;
			default = [ ];
			example = [ "/home/you/Pictures" ];
			description = "Library folders passed as --root to homesync-index (repeatable).";
		};

		indexInterval = mkOption {
			type = types.nullOr types.str;
			default = null;
			example = "daily";
			description = "systemd OnCalendar for homesync-index.timer. null disables the timer; `systemctl start homesync-index` still works.";
		};
	};

	config = mkIf cfg.enable (mkMerge [
		{
			systemd.tmpfiles.rules = [
				"d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
			];

			systemd.services.homesync = {
				description = "Homesync catalog daemon";
				after = [ "network.target" ];
				wantedBy = [ "multi-user.target" ];
				environment = envAttrs;
				serviceConfig = commonServiceConfig // {
					Type = "simple";
					ExecStart = getExe' cfg.package "homesync-server";
					Restart = "on-failure";
					RestartSec = "5s";
				};
			};

			systemd.services.homesync-index = {
				description = "Homesync library indexer";
				after = [ "homesync.service" ];
				environment = envAttrs;
				serviceConfig = commonServiceConfig // {
					Type = "oneshot";
					ExecStart =
						"${getExe' cfg.package "homesync-index"}"
						+ concatMapStringsSep "" (root: " --root ${escapeShellArg root}") cfg.indexRoots;
				};
			};

			environment.systemPackages = [ cfg.package ];

			networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
		}

		(mkIf cfg.createUser {
			users.users.${cfg.user} = {
				isSystemUser = true;
				group = cfg.group;
				home = cfg.dataDir;
				description = "Homesync catalog daemon";
			};
			users.groups.${cfg.group} = { };
		})

		(mkIf (cfg.indexInterval != null) {
			systemd.timers.homesync-index = {
				description = "Homesync library indexer";
				wantedBy = [ "timers.target" ];
				timerConfig = {
					OnCalendar = cfg.indexInterval;
					Persistent = true;
					Unit = "homesync-index.service";
				};
			};
		})
	]);
}
