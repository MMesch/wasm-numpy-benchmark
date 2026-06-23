{
  description = "numpy native vs WASM (Pyodide / pyjs) benchmark dev environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    sysnix = {
      url = "git+file:/home/matto/.config/nixpkgs?ref=master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, sysnix, nixpkgs }:
  let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;

    fhs = pkgs.buildFHSEnv {
      name = "wasm-bench-dev";

      targetPkgs = pkgs: with pkgs; [
        micromamba

        # C/C++ toolchain + disassembly (native arm)
        gcc
        gnumake
        cmake
        pkg-config
        gdb
        binutils
        stdenv.cc.cc.lib

        # Python (native arm; also used to drive empack/timing.py)
        python3

        # Node / JS toolchain (WASM arms)
        nodejs

        # Browser (optional: for interactive pyjs page debugging)
        ungoogled-chromium

        # Editor / shell ergonomics
        opencode
        neovim
        git
      ];

      profile = ''
        eval "$(micromamba shell hook --shell=posix)"
        export MAMBA_ROOT_PREFIX=$HOME/.mamba

        export PATH="$HOME/.local/bin:$PATH"
        if ! command -v empack &> /dev/null; then
          python3 -m pip install --user empack
        fi
      '';
    };

  in
  {
    devShells.x86_64-linux.default = fhs.env;

    nixosConfigurations.devvm =
      sysnix.nixosConfigurations.dev-vm.extendModules {
        modules = [
          {
            environment.systemPackages = [ fhs ];

            virtualisation = {
              diskSize = 8192;
            };

            networking.firewall.allowedTCPPorts = [ 8888 8889 ];
          }
        ];
      };
  };
}
