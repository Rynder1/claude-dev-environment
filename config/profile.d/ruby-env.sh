# Make Ruby usable for the non-root `node` user.
#
# By default `gem install` (without sudo) targets a system directory node can't
# write, and the per-user gem bin dir isn't on PATH - so gems install to an
# unpredictable place and their executables aren't runnable. Point GEM_HOME at a
# writable dir on the persistent ~/.claude volume: `gem install foo` and
# `bundle install` then work with no sudo, their executables are on PATH, and the
# installed gems survive scripts/rebuild.sh (same volume that holds git auth).
if command -v ruby >/dev/null 2>&1; then
	export GEM_HOME="$HOME/.claude/gems"
	case ":$PATH:" in
		*":$GEM_HOME/bin:"*) ;;
		*) export PATH="$GEM_HOME/bin:$PATH" ;;
	esac
fi
