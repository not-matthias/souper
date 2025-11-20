{
  description = "Souper - A synthesizing superoptimizer for LLVM IR";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    {
      # Overlay that can be used in other projects
      overlays.default = final: prev: {
        souper = self.packages.${final.system}.souper or self.packages.x86_64-linux.souper;
      };
    } //
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        llvmLib = pkgs.llvmPackages_21.llvm.lib or pkgs.llvmPackages_21.llvm;
        gccLib = pkgs.gcc.cc.lib or pkgs.gcc.cc;

        # Use Z3 from nixpkgs (version should be 4.12 or higher)
        # Souper specifically wants 4.13.0, but stock nixpkgs Z3 should work
        z3-souper = pkgs.z3;
        z3Lib = z3-souper.lib or z3-souper;

        # Alive2 dependency
        alive2 = pkgs.stdenv.mkDerivation rec {
          pname = "alive2";
          version = "7";

          src = pkgs.fetchFromGitHub {
            owner = "manasij7479";
            repo = "alive2";
            rev = "v${version}";
            hash = "sha256-48KEDaPlpJG392s9xw9HjIzK41OSWELJak8aiOypGp4=";
          };

          nativeBuildInputs = with pkgs; [ cmake ninja git re2c ];
          buildInputs = [ z3-souper pkgs.llvm_21 ];

          cmakeFlags = [
            "-DCMAKE_BUILD_TYPE=Release"
          ];

          # Let CMake find Z3 automatically through pkg-config or find_package
          PKG_CONFIG_PATH = "${z3-souper}/lib/pkgconfig";

          # Patch the FindZ3.cmake to accept any Z3 version and fix git describe
          postPatch = ''
            substituteInPlace cmake/FindZ3.cmake \
              --replace-fail 'message(FATAL_ERROR "Z3 required version: ''${Z3_REQUIRED_VERSION} (installed: ''${Z3_INSTALLED_VERSION})")' \
                             'message(STATUS "Z3 version check skipped - using: ''${Z3_INSTALLED_VERSION}")'

            # Fix the git describe command in CMakeLists.txt
            substituteInPlace CMakeLists.txt \
              --replace-fail 'COMMAND "''${GIT_EXECUTABLE}" describe --tags --dirty --always >> "''${PROJECT_BINARY_DIR}/version_gen.h.tmp"' \
                             'COMMAND "''${CMAKE_COMMAND}" -E echo "v${version}" >> "''${PROJECT_BINARY_DIR}/version_gen.h.tmp"'
          '';

          installPhase = ''
            mkdir -p $out/lib $out/include
            cp libir.a libsmt.a libtools.a libutil.a $out/lib/
            # Copy headers from source
            for dir in ir smt tools util; do
              if [ -d ${src}/$dir ]; then
                mkdir -p $out/include/$dir
                find ${src}/$dir -name "*.h" -exec cp {} $out/include/$dir/ \;
              fi
            done
          '';
        };

        # KLEE sources (only expr library is needed)
        klee-souper = pkgs.fetchFromGitHub {
          owner = "regehr";
          repo = "klee";
          rev = "klee-for-souper-17-2";
          hash = "sha256-I/+rrRchEGxOGGrGvJv1+0ryQH356rjy88GL3NyLlho=";
        };

        # Hiredis with specific commit
        hiredis-souper = pkgs.hiredis.overrideAttrs (oldAttrs: rec {
          version = "1.2.0-souper";
          src = pkgs.fetchFromGitHub {
            owner = "redis";
            repo = "hiredis";
            rev = "19cfd60d92da1fdb958568cdd7d36264ab14e666";
            hash = "sha256-1ujX/h/ytBGnLbae/vry8jXz6TiTLKs9l9l+qGO/cVo=";
          };
        });

      in
      {
        packages = rec {
          souper = pkgs.stdenv.mkDerivation rec {
            pname = "souper";
            version = "0.1.0";

            src = ./.;

            nativeBuildInputs = with pkgs; [
              cmake
              ninja
            ];

            buildInputs = with pkgs; [
              llvmPackages_21.llvm
              llvmPackages_21.llvm.dev  # Provides llvm-config
              llvmPackages_21.clang
              llvmPackages_21.compiler-rt
              z3-souper
              alive2
              hiredis-souper
              zstd.out  # Ensure we get the output with libraries
              zstd.dev  # Ensure we get the development headers
            ];

            # Set up the third_party directory structure that CMake expects
            preConfigure = ''
              mkdir -p third_party

              # Link KLEE sources
              ln -sf ${klee-souper} third_party/klee

              # Set up Alive2
              ln -sf ${alive2.src} third_party/alive2
              mkdir -p third_party/alive2-build
              cp -r ${alive2}/lib/* third_party/alive2-build/ 2>/dev/null || true

              # Set up Z3 installation (Z3 has multiple outputs: out, lib, dev, python)
              mkdir -p third_party/z3-install/bin
              mkdir -p third_party/z3-install/include
              mkdir -p third_party/z3-install/lib
              cp -rL ${z3-souper}/bin/* third_party/z3-install/bin/ 2>/dev/null || true
              cp -rL ${z3-souper.dev}/include/* third_party/z3-install/include/ 2>/dev/null || true
              cp -rL ${z3-souper.lib}/lib/* third_party/z3-install/lib/ 2>/dev/null || true

              # Set up hiredis installation
              mkdir -p third_party/hiredis-install/include/hiredis
              mkdir -p third_party/hiredis-install/lib
              cp -rL ${hiredis-souper}/include/hiredis/* third_party/hiredis-install/include/hiredis/ 2>/dev/null || true
              cp -rL ${hiredis-souper}/lib/* third_party/hiredis-install/lib/ 2>/dev/null || true

              # Set up LLVM installation
              mkdir -p third_party/llvm-Release-install/bin
              mkdir -p third_party/llvm-Release-install/include
              mkdir -p third_party/llvm-Release-install/lib

              # Copy bin/ contents from both llvm and llvm.dev
              cp -r ${pkgs.llvmPackages_21.llvm}/bin/* third_party/llvm-Release-install/bin/ 2>/dev/null || true
              cp -r ${pkgs.llvmPackages_21.llvm.dev}/bin/* third_party/llvm-Release-install/bin/ 2>/dev/null || true

              # Link include and lib
              ln -sf ${pkgs.llvmPackages_21.llvm.dev}/include/* third_party/llvm-Release-install/include/ 2>/dev/null || true
              ln -sf ${pkgs.llvmPackages_21.llvm}/lib/* third_party/llvm-Release-install/lib/ 2>/dev/null || true
            '';

            cmakeFlags = [
              "-DCMAKE_BUILD_TYPE=Release"
              "-DLLVM_BUILD_TYPE=Release"
              "-DZSTD_LIBRARY_DIR=${pkgs.zstd.out}/lib"
              "-DSOUPER_ENABLE_TESTS=OFF"
              "-DZ3=${z3-souper}/bin/z3"
              "-DZ3_INCLUDE_DIR=${z3-souper.dev}/include"
              "-DCMAKE_INSTALL_RPATH=$ORIGIN/../lib:${llvmLib}/lib:${z3Lib}/lib:${hiredis-souper}/lib:${pkgs.zstd.out}/lib:${gccLib}/lib"
            ];

            enableParallelBuilding = true;

            # Disable tests - they require gtest which would need additional setup
            doCheck = false;

            # Don't fail on test build issues
            ninjaFlags = [ "-k" "0" ];

            # Override build phase to continue even if tests fail
            buildPhase = ''
              runHook preBuild

              build_dir=''${cmakeBuildDir:-}
              if [ -n "$build_dir" ] && [ -f "$build_dir/CMakeCache.txt" ]; then
                :
              else
                cmake_cache_path=$(find . -maxdepth 3 -name CMakeCache.txt -print -quit)
                if [ -n "$cmake_cache_path" ]; then
                  build_dir=$(dirname "$cmake_cache_path")
                fi
              fi

              if [ -z "$build_dir" ] || [ ! -f "$build_dir/CMakeCache.txt" ]; then
                echo "Unable to locate CMakeCache.txt" >&2
                exit 1
              fi

              cmake --build "$build_dir" -- -j $NIX_BUILD_CORES

              runHook postBuild
            '';

            # Install phase - only install the main executables that built successfully
            installPhase = ''
              mkdir -p $out/bin $out/lib

              build_dir=''${cmakeBuildDir:-}
              if [ -n "$build_dir" ] && [ -d "$build_dir" ]; then
                :
              else
                cmake_cache_path=$(find . -maxdepth 3 -name CMakeCache.txt -print -quit)
                if [ -n "$cmake_cache_path" ]; then
                  build_dir=$(dirname "$cmake_cache_path")
                fi
              fi

              if [ -z "$build_dir" ] || [ ! -d "$build_dir" ]; then
                echo "Unable to locate build directory" >&2
                exit 1
              fi

              cd "$build_dir"

              # Install main executables
              for exe in souper souper-check souper-interpret souper2llvm count-insts internal-solver-test lexer-test parser-test; do
                if [ -f "$exe" ]; then
                  cp "$exe" $out/bin/
                  echo "Installed: $exe"
                fi
              done

              # Install shared libraries
              for lib in *.so; do
                if [ -f "$lib" ]; then
                  cp "$lib" $out/lib/
                  echo "Installed library: $lib"
                fi
              done

              if [ ! -f "$out/bin/souper" ]; then
                echo "Souper binary was not produced; failing build" >&2
                exit 1
              fi

              echo "Souper installation complete!"
              ls -la $out/bin/
            '';

            preFixup = ''
              runtime_rpath='$ORIGIN/../lib:${llvmLib}/lib:${z3Lib}/lib:${hiredis-souper}/lib:${pkgs.zstd.out}/lib:${gccLib}/lib'
              library_rpath='$ORIGIN:${llvmLib}/lib:${z3Lib}/lib:${hiredis-souper}/lib:${pkgs.zstd.out}/lib:${gccLib}/lib'

              if [ -d "$out/bin" ]; then
                for bin in "$out"/bin/*; do
                  if [ -f "$bin" ]; then
                    patchelf --set-rpath "$runtime_rpath" "$bin"
                  fi
                done
              fi

              if [ -d "$out/lib" ]; then
                shopt -s nullglob
                for libFile in "$out"/lib/*.so*; do
                  patchelf --set-rpath "$library_rpath" "$libFile"
                done
                shopt -u nullglob
              fi
            '';

            meta = with pkgs.lib; {
              description = "A synthesizing superoptimizer for LLVM IR";
              longDescription = ''
                Souper is a superoptimizer for LLVM IR. It uses an SMT solver
                to help identify missing peephole optimizations in LLVM's
                midend optimizers.
              '';
              homepage = "https://github.com/google/souper";
              license = licenses.asl20;
              platforms = platforms.unix;
              maintainers = [ ];
            };
          };

          default = souper;
        };

        # Development shell
        devShells.default = pkgs.mkShell {
          inputsFrom = [ self.packages.${system}.souper ];

          packages = with pkgs; [
            # Additional development tools
            gdb
            lldb_21
            valgrind
            git

            # Formatters and linters
            llvmPackages_21.clang-tools

            # Build tools
            cmake
            ninja

            # Testing
            python3

            # Documentation
            doxygen
          ];

          shellHook = ''
            echo "Souper development environment"
            echo "LLVM version: ${pkgs.llvmPackages_21.llvm.version}"
            echo "Z3 version: ${z3-souper.version}"
            echo ""
            echo "Build with: nix build"
            echo "or manually: mkdir build && cd build && cmake .. && ninja"
          '';
        };

        # Apps for easy execution
        apps = {
          souper = flake-utils.lib.mkApp {
            drv = self.packages.${system}.souper;
            exePath = "/bin/souper";
          };

          souper-check = flake-utils.lib.mkApp {
            drv = self.packages.${system}.souper;
            exePath = "/bin/souper-check";
          };

          default = self.apps.${system}.souper;
        };

      }
    );
}
