#!/usr/bin/env bash
# update-readme.sh — refresh the auto-generated parts of README.md from the live GitHub API.
# Curated content (which repos appear, their descriptions) lives in data/*.json and is hand-edited;
# this script only refreshes mechanical data: per-repo commit counts/last-active/stars, the
# top-level repo-count summary, and the Deep Commit Statistics table. Requires: gh (authenticated
# as the profile owner, so it can see private repos too), jq, python3.
set -euo pipefail

OWNER="chandrasaripaka"
README="README.md"

commit_count() {
  # GitHub's REST API has no direct "total commits" field; the standard trick is reading the
  # last page number off the Link header of a 1-per-page commits request.
  local repo="$1"
  local link
  link="$(gh api "repos/$OWNER/$repo/commits?per_page=1" -i 2>/dev/null | grep -i '^link:' || true)"
  if [ -z "$link" ]; then
    gh api "repos/$OWNER/$repo/commits?per_page=1" --jq 'length' 2>/dev/null || echo 0
    return
  fi
  echo "$link" | grep -oE 'page=[0-9]+>; rel="last"' | grep -oE '[0-9]+' || echo "?"
}

last_active() {
  local repo="$1"
  gh api "repos/$OWNER/$repo" --jq '.pushed_at' 2>/dev/null | cut -c1-7 || echo "?"
}

stars() {
  local repo="$1"
  gh api "repos/$OWNER/$repo" --jq '.stargazers_count' 2>/dev/null || echo 0
}

echo "Building Featured Work table..."
featured_rows=""
while IFS=$'\t' read -r repo label stack; do
  c="$(commit_count "$repo")"
  d="$(last_active "$repo")"
  featured_rows+="| $label | $stack | $c | $d |"$'\n'
done < <(jq -r '.[] | [.repo, .label, .stack] | @tsv' data/featured.json)

echo "Building Open Source table..."
os_rows=""
while IFS=$'\t' read -r repo desc stack; do
  s="$(stars "$repo")"
  c="$(commit_count "$repo")"
  os_rows+="| [$repo](https://github.com/$OWNER/$repo) | $desc | $stack | ⭐ $s | $c |"$'\n'
done < <(jq -r '.[] | [.repo, .description, .stack] | @tsv' data/opensource.json)

echo "Fetching full owned-repo list (public + private, via authenticated endpoint)..."
# user/repos (not users/OWNER/repos) so private repos the token owns are included too.
all_repos_json="$(gh api "user/repos?per_page=100&affiliation=owner" --paginate --jq '.' 2>/dev/null || echo '[]')"
all_repos_json="$(echo "$all_repos_json" | jq -s 'add')"

total="$(echo "$all_repos_json" | jq 'length')"
public_n="$(echo "$all_repos_json" | jq '[.[] | select(.private == false)] | length')"
private_n="$(echo "$all_repos_json" | jq '[.[] | select(.private == true)] | length')"
forks_n="$(echo "$all_repos_json" | jq '[.[] | select(.fork == true)] | length')"
nonfork_n="$(echo "$all_repos_json" | jq '[.[] | select(.fork == false)] | length')"
summary_line="- 📈 $total repositories ($public_n public · $private_n private · $forks_n forks), spanning 2013–present."

echo "Computing per-repo commit counts across all owned NON-FORK repos (this is the slow part)..."
nonfork_names="$(echo "$all_repos_json" | jq -r '.[] | select(.fork == false) | .name')"
stats_rows_file="$(mktemp)"
total_commits=0
private_commits=0
private_repo_ct=0
public_commits=0
public_repo_ct=0
busiest_repo=""
busiest_count=0
while IFS= read -r name; do
  [ -z "$name" ] && continue
  cnt="$(commit_count "$name")"
  [[ "$cnt" =~ ^[0-9]+$ ]] || cnt=0
  is_private="$(echo "$all_repos_json" | jq -r --arg n "$name" '.[] | select(.name == $n) | .private')"
  echo -e "${name}\t${cnt}\t${is_private}" >> "$stats_rows_file"
  total_commits=$((total_commits + cnt))
  if [ "$is_private" = "true" ]; then
    private_commits=$((private_commits + cnt)); private_repo_ct=$((private_repo_ct + 1))
  else
    public_commits=$((public_commits + cnt)); public_repo_ct=$((public_repo_ct + 1))
  fi
  if [ "$cnt" -gt "$busiest_count" ]; then busiest_count="$cnt"; busiest_repo="$name"; fi
done <<< "$nonfork_names"

echo "Fetching PR authorship counts..."
pr_total="$(gh api "search/issues?q=author:$OWNER+type:pr" --jq '.total_count' 2>/dev/null || echo 0)"
pr_merged="$(gh api "search/issues?q=author:$OWNER+type:pr+is:merged" --jq '.total_count' 2>/dev/null || echo 0)"
pr_open="$(gh api "search/issues?q=author:$OWNER+type:pr+is:open" --jq '.total_count' 2>/dev/null || echo 0)"

echo "Summing total stars..."
total_stars="$(echo "$all_repos_json" | jq '[.[] | select(.fork == false) | .stargazers_count] | add // 0')"

echo "Computing language mix (bytes-weighted across owned non-fork repos)..."
lang_totals_file="$(mktemp)"
while IFS= read -r name; do
  [ -z "$name" ] && continue
  gh api "repos/$OWNER/$name/languages" 2>/dev/null | jq -r 'to_entries[] | "\(.key)\t\(.value)"' >> "$lang_totals_file" || true
done <<< "$nonfork_names"
primary_lang="$(jq -R -s -r '
  split("\n") | map(select(length > 0) | split("\t")) |
  reduce .[] as $row ({}; .[$row[0]] = ((.[$row[0]] // 0) + ($row[1] | tonumber))) |
  to_entries | sort_by(-.value) | .[0].key // "TypeScript"
' "$lang_totals_file" 2>/dev/null || echo "TypeScript")"
top_langs_by_repo="$(echo "$all_repos_json" | jq -r '[.[] | select(.fork == false) | .language] | map(select(. != null)) | group_by(.) | sort_by(-length) | map(.[0]) | .[0:4] | join(" · ")' 2>/dev/null || echo "?")"

rm -f "$stats_rows_file" "$lang_totals_file"

today="$(date -u +%Y-%m-%d)"
stats_note="<sub>Computed ${today} from each owned <b>non-fork</b> repo's default-branch history via the GitHub REST API — more accurate than the public contribution graph (which only counts commits made with a GitHub-verified email). Forks are excluded on purpose: counting their upstream history would wildly overstate the numbers.</sub>"

stats_table="$(cat <<TABLEEOF
| Metric | Value |
|---|---|
| Total repositories | $total ($public_n public · $private_n private · $forks_n forks) |
| Original (non-fork) repositories | $nonfork_n |
| **Total commits across owned repos** | **$total_commits** |
| — commits in private repos | $private_commits ($private_repo_ct repos) |
| — commits in public repos | $public_commits ($public_repo_ct repos) |
| Pull requests authored | $pr_total ($pr_merged merged · $pr_open open) |
| Total stars earned | $total_stars |
| Busiest repo by commits | \`$busiest_repo\` — $busiest_count commits |
| Primary language by code volume | $primary_lang (bytes-weighted across owned non-fork repos) |
| Top languages by repo count | $top_langs_by_repo |
| Account age | 12+ years (since March 2013) |
TABLEEOF
)"

echo "Splicing into ${README}..."
python3 - "$README" "$summary_line" "$featured_rows" "$os_rows" "$public_n" "$stats_note" "$stats_table" <<'PYEOF'
import sys, re

readme_path, summary_line, featured_rows, os_rows, public_n, stats_note, stats_table = sys.argv[1:8]

with open(readme_path, "r", encoding="utf-8") as f:
    text = f.read()

def splice(text, start_marker, end_marker, new_body):
    pattern = re.compile(re.escape(start_marker) + r".*?" + re.escape(end_marker), re.DOTALL)
    replacement = start_marker + "\n" + new_body.rstrip("\n") + "\n" + end_marker
    new_text, n = pattern.subn(replacement, text)
    if n == 0:
        raise SystemExit(f"markers not found: {start_marker} .. {end_marker}")
    return new_text

text = splice(text, "<!-- AUTO:REPO-SUMMARY:START -->", "<!-- AUTO:REPO-SUMMARY:END -->", summary_line)
text = splice(text, "<!-- AUTO:FEATURED-TABLE:START -->", "<!-- AUTO:FEATURED-TABLE:END -->",
              "| Project | Stack | Commits | Last Active |\n|---|---|---|---|\n" + featured_rows)
text = splice(text, "<!-- AUTO:OPENSOURCE-TABLE:START -->", "<!-- AUTO:OPENSOURCE-TABLE:END -->",
              "| Project | Description | Stack | Stars | Commits |\n|---|---|---|---|---|\n" + os_rows)
text = splice(text, "<!-- AUTO:STATS-NOTE:START -->", "<!-- AUTO:STATS-NOTE:END -->", stats_note)
text = splice(text, "<!-- AUTO:STATS-TABLE:START -->", "<!-- AUTO:STATS-TABLE:END -->", stats_table)
text = re.sub(r"Full list of \d+ public repos", f"Full list of {public_n} public repos", text)

with open(readme_path, "w", encoding="utf-8") as f:
    f.write(text)

print("README.md updated.")
PYEOF

echo "Done."
