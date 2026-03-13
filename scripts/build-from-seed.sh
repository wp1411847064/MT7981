#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TOPDIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DEFAULT_SEED="configs/devices/mediatek_filogic_myboard_my-mt7981.seed"
DEFAULT_FRAGMENT="configs/fragments/mediatek_filogic_myboard_my-mt7981.postconfig"
SEED_PATH="$DEFAULT_SEED"
FRAGMENT_PATH="$DEFAULT_FRAGMENT"
CONFIG_ONLY=0
REUSE_CONFIG=0
DRY_RUN=0
BUILD_MODE="full"
IMAGE_AFTER=0
PACKAGE_TARGETS=""
EXTRA_TARGETS=""
MAKE_ARGS=""
JOBS=""
SEED_EXPLICIT=0

usage() {
	cat <<'EOF'
Usage:
	./scripts/build-from-seed.sh [options] [seed-path] [-- make-args...]

Examples:
  ./scripts/build-from-seed.sh
  ./scripts/build-from-seed.sh --config-only
	./scripts/build-from-seed.sh --package busybox --image --jobs 8 -- V=s
  ./scripts/build-from-seed.sh --kernel --image
  ./scripts/build-from-seed.sh --target package/network/services/dnsmasq/compile

Options:
  --config-only          Only regenerate .config and stop
  --reuse-config         Do not overwrite existing .config from seed
	--jobs N               Override detected parallel job count
  --package NAME|PATH    Compile one package; can be specified multiple times
  --kernel               Rebuild target/linux
  --image                Repack final firmware image after partial build
  --full                 Run full build (default)
  --target MAKE_TARGET   Append a raw make target; can be specified multiple times
  --dry-run              Pass -n to make to print commands without executing
  -h, --help             Show this help
EOF
}

append_word() {
	value="$1"
	list="$2"
	if [ -n "$list" ]; then
		printf '%s %s' "$list" "$value"
	else
		printf '%s' "$value"
	fi
}

resolve_package_dir() {
	package_input="$1"

	case "$package_input" in
		package/*)
			if [ -f "$TOPDIR/$package_input/Makefile" ]; then
				printf '%s\n' "$package_input"
				return 0
			fi
			;;
		feeds/*)
			if [ -f "$TOPDIR/package/$package_input/Makefile" ]; then
				printf '%s\n' "package/$package_input"
				return 0
			fi
			;;
		*/*)
			if [ -f "$TOPDIR/$package_input/Makefile" ]; then
				printf '%s\n' "$package_input"
				return 0
			fi
			if [ -f "$TOPDIR/package/$package_input/Makefile" ]; then
				printf '%s\n' "package/$package_input"
				return 0
			fi
			;;
	esac

	matches=$(find "$TOPDIR/package" -path "*/$package_input/Makefile" -print 2>/dev/null | sed "s#^$TOPDIR/##")
	match_count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')

	if [ "$match_count" -eq 1 ]; then
		printf '%s\n' "${matches%/Makefile}"
		return 0
	fi

	if [ "$match_count" -gt 1 ]; then
		echo "Package name is ambiguous: $package_input" >&2
		printf '%s\n' "$matches" | sed '/^$/d' >&2
		return 1
	fi

	echo "Package not found: $package_input" >&2
	return 1
}

run_make() {
	if [ "$DRY_RUN" -eq 1 ]; then
		set -- -n "$@"
	fi

	echo "make $*"
	make "$@"
}

detect_jobs() {
	if [ -n "$JOBS" ]; then
		printf '%s\n' "$JOBS"
		return 0
	fi

	if command -v nproc >/dev/null 2>&1; then
		nproc
		return 0
	fi

	if command -v getconf >/dev/null 2>&1; then
		getconf _NPROCESSORS_ONLN
		return 0
	fi

	printf '1\n'
}

ensure_make_args() {
	case " $MAKE_ARGS " in
		*" -j"*|*" -j"[0-9]*|*" --jobs "*|*" --jobs="*)
			return 0
			;;
	esac

	parallel_jobs=$(detect_jobs)
	if [ -n "$MAKE_ARGS" ]; then
		MAKE_ARGS="-j$parallel_jobs $MAKE_ARGS"
	else
		MAKE_ARGS="-j$parallel_jobs"
	fi
}

sync_config() {
	echo "make defconfig"
	make defconfig
}

apply_config_line() {
	line="$1"
	case "$line" in
		"" )
			return 0
			;;
		\#\ CONFIG_*\ is\ not\ set)
			symbol=${line#\# }
			symbol=${symbol% is not set}
			;;
		CONFIG_*=*)
			symbol=${line%%=*}
			;;
		\#*)
			return 0
			;;
		*)
			echo "Unsupported config fragment line: $line" >&2
			exit 1
			;;
	esac

	awk -v symbol="$symbol" -v newline="$line" '
		BEGIN { replaced = 0 }
		$0 ~ "^" symbol "=" {
			if (!replaced) {
				print newline
				replaced = 1
			}
			next
		}
		$0 == "# " symbol " is not set" {
			if (!replaced) {
				print newline
				replaced = 1
			}
			next
		}
		{ print }
		END {
			if (!replaced) {
				print newline
			}
		}
	' .config > .config.tmp
	mv .config.tmp .config
}

apply_fragment() {
	fragment_file="$1"
	[ -f "$fragment_file" ] || return 0

	while IFS= read -r line || [ -n "$line" ]; do
		apply_config_line "$line"
	done < "$fragment_file"
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	usage
	exit 0
fi

while [ "$#" -gt 0 ]; do
	case "$1" in
		--config-only)
			CONFIG_ONLY=1
			shift
			;;
		--reuse-config)
			REUSE_CONFIG=1
			shift
			;;
		--jobs)
			[ "$#" -ge 2 ] || { echo "Missing value for --jobs" >&2; exit 1; }
			JOBS="$2"
			shift 2
			;;
		--package)
			[ "$#" -ge 2 ] || { echo "Missing value for --package" >&2; exit 1; }
			resolved_package=$(resolve_package_dir "$2")
			PACKAGE_TARGETS=$(append_word "$resolved_package/compile" "$PACKAGE_TARGETS")
			BUILD_MODE="partial"
			shift 2
			;;
		--kernel)
			EXTRA_TARGETS=$(append_word "target/linux/compile" "$EXTRA_TARGETS")
			BUILD_MODE="partial"
			shift
			;;
		--image)
			IMAGE_AFTER=1
			shift
			;;
		--full)
			BUILD_MODE="full"
			shift
			;;
		--target)
			[ "$#" -ge 2 ] || { echo "Missing value for --target" >&2; exit 1; }
			EXTRA_TARGETS=$(append_word "$2" "$EXTRA_TARGETS")
			BUILD_MODE="partial"
			shift 2
			;;
		--dry-run)
			DRY_RUN=1
			shift
			;;
		--)
			shift
			MAKE_ARGS="$*"
			break
			;;
		-*)
			echo "Unknown option: $1" >&2
			usage >&2
			exit 1
			;;
		*)
			if [ "$SEED_EXPLICIT" -eq 0 ] && [ -f "$TOPDIR/$1" ]; then
				SEED_PATH="$1"
				SEED_EXPLICIT=1
			else
				MAKE_ARGS=$(append_word "$1" "$MAKE_ARGS")
			fi
			shift
			;;
	esac
	done

SEED_FILE="$TOPDIR/$SEED_PATH"
FRAGMENT_FILE="$TOPDIR/$FRAGMENT_PATH"

if [ ! -f "$SEED_FILE" ]; then
	echo "Seed file not found: $SEED_PATH" >&2
	exit 1
fi

if ! command -v make >/dev/null 2>&1; then
	echo "make not found in PATH" >&2
	exit 1
fi

cd "$TOPDIR"

if [ "$REUSE_CONFIG" -eq 0 ]; then
	cp "$SEED_FILE" .config
	sync_config
	apply_fragment "$FRAGMENT_FILE"
fi

if [ "$CONFIG_ONLY" -eq 1 ]; then
	if [ "$REUSE_CONFIG" -eq 1 ]; then
		echo "Reused existing .config"
	else
		echo "Generated .config from $SEED_PATH"
	fi
	if [ -f "$FRAGMENT_FILE" ] && [ "$REUSE_CONFIG" -eq 0 ]; then
		echo "Applied post-defconfig fragment $FRAGMENT_PATH"
	fi
	exit 0
fi

ensure_make_args

if [ "$BUILD_MODE" = "full" ]; then
	if [ -n "$MAKE_ARGS" ]; then
		# shellcheck disable=SC2086
		run_make $MAKE_ARGS
	else
		run_make
	fi
	exit 0
fi

BUILD_TARGETS="$PACKAGE_TARGETS"
if [ -n "$EXTRA_TARGETS" ]; then
	BUILD_TARGETS=$(append_word "$EXTRA_TARGETS" "$BUILD_TARGETS")
fi

if [ "$IMAGE_AFTER" -eq 1 ]; then
	if [ -n "$PACKAGE_TARGETS" ]; then
		BUILD_TARGETS=$(append_word "package/install" "$BUILD_TARGETS")
	fi
	BUILD_TARGETS=$(append_word "target/install" "$BUILD_TARGETS")
fi

if [ -z "$BUILD_TARGETS" ]; then
	echo "No partial build target selected; use --full or specify --package/--kernel/--target" >&2
	exit 1
fi

if [ -n "$MAKE_ARGS" ]; then
	# shellcheck disable=SC2086
	run_make $BUILD_TARGETS $MAKE_ARGS
else
	# shellcheck disable=SC2086
	run_make $BUILD_TARGETS
fi