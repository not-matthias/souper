# Using Souper with Nix

This repository includes a Nix flake that allows you to build and use Souper without manually managing dependencies.

## Quick Start

### Building Souper

```bash
# Build the project
nix build

# Run souper directly
nix run . -- --help

# Run souper-check
nix run .#souper-check -- --help
```

### Development Shell

Enter a development environment with all dependencies:

```bash
nix develop
```

This provides:
- LLVM 20 toolchain (clang, lldb, etc.)
- Z3 SMT solver (version 4.13.0)
- Alive2
- CMake and Ninja
- Development tools (gdb, valgrind, clang-tools)

### Using in Another Project

You can use Souper as a dependency in your own Nix flake:

#### Method 1: Direct Input

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    souper.url = "github:google/souper";  # or your fork
  };

  outputs = { self, nixpkgs, souper }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      packages.${system}.myproject = pkgs.stdenv.mkDerivation {
        name = "myproject";
        src = ./.;

        buildInputs = [
          souper.packages.${system}.souper
        ];
      };
    };
}
```

#### Method 2: Using the Overlay

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    souper.url = "github:google/souper";
  };

  outputs = { self, nixpkgs, souper }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ souper.overlays.default ];
      };
    in {
      packages.${system}.myproject = pkgs.stdenv.mkDerivation {
        name = "myproject";
        src = ./.;

        # souper is now available directly in pkgs
        buildInputs = [ pkgs.souper ];
      };
    };
}
```

#### Method 3: NixOS Configuration

Add to your NixOS configuration:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    souper.url = "github:google/souper";
  };

  outputs = { self, nixpkgs, souper }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ({ pkgs, ... }: {
          nixpkgs.overlays = [ souper.overlays.default ];

          environment.systemPackages = [
            pkgs.souper
          ];
        })
      ];
    };
  };
}
```

## Available Outputs

### Packages

- `packages.${system}.souper` - Main Souper package
- `packages.${system}.default` - Alias for souper

### Apps

- `apps.${system}.souper` - Run the souper binary
- `apps.${system}.souper-check` - Run souper-check
- `apps.${system}.default` - Alias for souper

### Development Shells

- `devShells.${system}.default` - Development environment with all dependencies

### Overlays

- `overlays.default` - Overlay that adds souper to nixpkgs

## Dependencies

The flake automatically handles these dependencies:

- **LLVM 20**: Complete LLVM toolchain with clang and compiler-rt
- **Z3 4.13.0**: SMT solver (built from source with specific version)
- **Alive2 v7**: Translation validator
- **hiredis**: Redis client library for caching
- **KLEE**: Symbolic execution engine (only expr library)
- **zstd**: Compression library

## Notes

### Custom LLVM Build

By default, the flake uses stock LLVM 20 from nixpkgs. The original Souper build uses a custom LLVM fork with disabled peepholes. If you need this:

1. You'll need to build LLVM from source (very time-consuming)
2. Update the flake to fetch from `regehr/llvm-project` with appropriate LLVM 20 branch
3. This is not included by default to keep build times reasonable

### Building from Local Source

When developing:

```bash
# Build with current source tree
nix build

# Enter dev shell
nix develop

# Traditional CMake build (inside nix develop)
mkdir build && cd build
cmake .. -GNinja
ninja
```

### Caching

The flake includes hiredis for Redis-based query caching. To use external caching:

1. Install and run Redis: `redis-server`
2. Use the `-souper-external-cache` flag when running souper

## Troubleshooting

### Build Failures

If the build fails:

1. Check that all Git submodules are up to date
2. Clean the build directory: `rm -rf build/`
3. Try rebuilding: `nix build --rebuild`

### Hash Mismatches

If you get hash mismatches for dependencies:

```bash
# Update the hash for a specific dependency
nix-shell -p nix-prefetch-git --run "nix-prefetch-git --url https://github.com/<owner>/<repo> --rev <commit>"
```

Then update the hash in `flake.nix`.

## Contributing

When modifying the flake:

1. Run `nix flake check` to validate
2. Test with `nix build`
3. Test the development shell with `nix develop`
4. Update this documentation if needed
