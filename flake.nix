{
	description = "Homesync — Linux file catalog + Flutter phone client";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable?shallow=1";
		flake-utils.url = "github:numtide/flake-utils?shallow=1";
	};

	outputs = { self, nixpkgs, flake-utils }:
		flake-utils.lib.eachDefaultSystem (system:
		let
			pkgs = import nixpkgs {
				inherit system;
				config.allowUnfree = true;
			};

			androidSdkRoot = "$HOME/.android-sdk";
			cmdlineToolsZip = "https://dl.google.com/android/repository/commandlinetools-linux-10406996_latest.zip";

			connectadb = pkgs.writeShellScriptBin "connectadb" ''
				TARGET_IP="$1"
				PORT_RANGE="32000-46000"

				echo "Searching for open ports..."
				PORTS=($(${pkgs.nmap}/bin/nmap "$TARGET_IP" -p "$PORT_RANGE" | awk '/\/tcp/ {print $1}' | cut -d/ -f1))
				echo "Port found: " $PORTS

				if [[ ''${#PORTS[@]} -eq 0 ]]; then
					echo "No open ADB port found in range $PORT_RANGE on $TARGET_IP"
					exit 1
				fi

				echo "Open ports found: ''${PORTS[@]}"

				for PORT in "''${PORTS[@]}"; do
					echo "Attempting to connect ADB to $TARGET_IP:$PORT..."
					adb connect "$TARGET_IP:$PORT" | tee /dev/stderr | grep -q "connected to" && echo "Connected!!!" && exit 0
				done
			'';

			installdeps = pkgs.writeShellScriptBin "installdeps" ''
				set -e

				export ANDROID_HOME=${androidSdkRoot}
				export ANDROID_SDK_ROOT=${androidSdkRoot}
				export PATH=$PATH:$ANDROID_HOME/platform-tools
				export PATH=$PATH:$ANDROID_HOME/emulator
				export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin
				export PATH=$PATH:$HOME/.pub-cache/bin

				echo "Installing Android SDK dependencies..."

				if [ ! -f "${androidSdkRoot}/cmdline-tools/latest/bin/sdkmanager" ]; then
					echo "Downloading Android Command Line Tools..."
					mkdir -p "${androidSdkRoot}/cmdline-tools/latest"
					cd "${androidSdkRoot}/cmdline-tools/latest"
					curl -o sdk-tools-linux.zip ${cmdlineToolsZip}
					unzip -o sdk-tools-linux.zip
					rm sdk-tools-linux.zip
				fi

				if [ -d "${androidSdkRoot}/cmdline-tools/latest/cmdline-tools" ]; then
					echo "Fixing Android SDK structure..."
					mv ${androidSdkRoot}/cmdline-tools/latest/cmdline-tools/* ${androidSdkRoot}/cmdline-tools/latest/
					rmdir ${androidSdkRoot}/cmdline-tools/latest/cmdline-tools
				fi

				requiredComponents=(
					"platform-tools"
					"platforms;android-35"
					"build-tools;33.0.1"
					"cmdline-tools;latest"
				)

				for component in "''${requiredComponents[@]}"; do
					if ! ${androidSdkRoot}/cmdline-tools/latest/bin/sdkmanager --list | grep -q "$component"; then
						echo "Installing $component..."
						${androidSdkRoot}/cmdline-tools/latest/bin/sdkmanager --install "$component"
					else
						echo "$component is already installed."
					fi
				done

				echo "Android SDK setup complete."
			'';

			androidPathHook = ''
				export ANDROID_HOME=${androidSdkRoot}
				export ANDROID_SDK_ROOT=${androidSdkRoot}
				export PATH=$PATH:$ANDROID_HOME/platform-tools
				export PATH=$PATH:$ANDROID_HOME/emulator
				export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin
				export PATH=$PATH:$HOME/.pub-cache/bin
			'';

			# uv manages a local .venv — avoids nixpkgs compiling pillow/scipy/etc.
			backendShell = pkgs.mkShell {
				packages = [
					pkgs.python312
					pkgs.uv
					pkgs.sqlite
					pkgs.ruff
				];
				shellHook = ''
					echo "homesync backend (Python + uv)"
					export UV_PROJECT_ENVIRONMENT="$PWD/backend/.venv"
					export PYTHONPATH="$PWD/backend/src''${PYTHONPATH:+:$PYTHONPATH}"
					if [ ! -d "$PWD/backend/.venv" ]; then
						echo "Tip: cd backend && uv sync"
					fi
				'';
			};

			mobileShell = pkgs.mkShell {
				packages = [
					pkgs.flutter
					pkgs.jdk17
					pkgs.gradle
					pkgs.android-tools
					pkgs.unzip
					pkgs.curl
					pkgs.nmap
					pkgs.sqlite # Drift NativeDatabase / flutter test needs libsqlite3
					connectadb
					installdeps
				];
				shellHook = ''
					echo "homesync mobile (Flutter)"
					${androidPathHook}
					# Expose libsqlite3 for Drift/sqlite3 FFI in `flutter test`
					export LD_LIBRARY_PATH="${pkgs.sqlite.out}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
					export HOMESYNC_SQLITE3_LIB="${pkgs.sqlite.out}/lib/libsqlite3.so"
				'';
			};
		in {
			# Default is backend-only so direnv/`nix develop` stay light on potato PCs.
			# Use `nix develop .#mobile` (or `use flake .#mobile` in .envrc) for Flutter.
			devShells = {
				default = backendShell;
				backend = backendShell;
				mobile = mobileShell;
			};

			devShell = backendShell;
		});
}
