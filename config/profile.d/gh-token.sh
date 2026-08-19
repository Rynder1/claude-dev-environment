# Auto-authenticate the GitHub CLI (gh) from the token that setup-git-auth.sh
# already stored on the persistent volume. gh reads GH_TOKEN from the environment,
# so exporting it here means `gh` is authed in every shell without a separate
# `gh auth login` (which would write to ~/.config/gh and be lost on rebuild).
#
# The credential file holds a single line of the form:
#   https://x-access-token:<TOKEN>@github.com
# We extract <TOKEN> and export it. Sourced by every login shell via /etc/profile.d.
if [ -z "${GH_TOKEN:-}" ]; then
	_gh_cred="$HOME/.claude/.git-credentials"
	if [ -r "$_gh_cred" ]; then
		_gh_tok="$(sed -n 's#^https://[^:]*:\([^@]*\)@github\.com.*#\1#p' "$_gh_cred" | head -1)"
		if [ -n "$_gh_tok" ]; then
			export GH_TOKEN="$_gh_tok"
			# Some Ruby/platform tooling reads GITHUB_TOKEN instead; mirror it unless
			# it's already set by something else.
			[ -z "${GITHUB_TOKEN:-}" ] && export GITHUB_TOKEN="$_gh_tok"
		fi
		unset _gh_tok
	fi
	unset _gh_cred
fi
