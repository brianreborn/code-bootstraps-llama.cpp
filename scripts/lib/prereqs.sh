# shellcheck shell=sh
# Build prerequisites per platform (README "Build prerequisites"). Sourced by build-*.sh and
# scripts/predownload.sh. prereqs_platform -> linux-apt|linux-dnf|linux-pacman|linux|macos|termux|freebsd

prereqs_platform() {
  case "${PREFIX:-}" in *com.termux*) echo termux; return ;; esac
  case "$(uname -s)" in
    Darwin) echo macos ;;
    FreeBSD) echo freebsd ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then echo linux-apt
      elif command -v dnf >/dev/null 2>&1; then echo linux-dnf
      elif command -v pacman >/dev/null 2>&1; then echo linux-pacman
      else echo linux; fi ;;
    *) echo unknown ;;
  esac
}

# packages that provide: C/C++ compiler, cmake, ninja, git, curl, tar, patch tools
prereqs_packages() {
  case "$(prereqs_platform)" in
    linux-apt) echo "build-essential cmake ninja-build git curl ca-certificates tar" ;;
    linux-dnf) echo "gcc gcc-c++ make cmake ninja-build git curl tar" ;;
    linux-pacman) echo "base-devel cmake ninja git curl tar" ;;
    macos) echo "cmake ninja git" ;;          # + Xcode Command Line Tools (xcode-select --install)
    termux) echo "clang cmake ninja git curl tar binutils" ;;
    freebsd) echo "cmake ninja git curl" ;;
    *) echo "a C/C++ compiler, cmake, git, curl, tar" ;;
  esac
}

prereqs_install_hint() {
  pk=$(prereqs_packages)
  case "$(prereqs_platform)" in
    linux-apt) echo "sudo apt-get install -y $pk" ;;
    linux-dnf) echo "sudo dnf install -y $pk" ;;
    linux-pacman) echo "sudo pacman -S --needed $pk" ;;
    macos) echo "xcode-select --install && brew install $pk" ;;
    termux) echo "pkg install -y $pk" ;;
    freebsd) echo "pkg install -y $pk" ;;
    *) echo "install: $pk" ;;
  esac
}

# prereqs_check build: every tool a source build needs; prints what is missing + how to install
prereqs_check() {
  pc_missing=""
  if [ "$(prereqs_platform)" = termux ]; then cc_list="clang clang++"; else cc_list="cc c++"; fi
  for pc_t in $cc_list cmake git curl tar; do
    command -v "$pc_t" >/dev/null 2>&1 || pc_missing="$pc_missing $pc_t"
  done
  if [ -n "$pc_missing" ]; then
    echo "prereqs: missing:$pc_missing" >&2
    echo "prereqs: install them with: $(prereqs_install_hint)" >&2
    echo "prereqs: (offline later? run scripts/predownload.sh first while online)" >&2
    return 1
  fi
  command -v ninja >/dev/null 2>&1 || echo "prereqs: ninja not found; using make (slower). $(prereqs_install_hint)" >&2
  return 0
}
