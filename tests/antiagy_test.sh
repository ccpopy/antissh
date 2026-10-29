#!/usr/bin/env bash
# Integration smoke test with a disposable HOME and native ELF stand-ins.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
export HOME="$fixture/home"
export AGY_CALL_LOG="$fixture/agy.log"
export GRAFTCP_CALL_LOG="$fixture/graftcp.log"
mkdir -p "$HOME/.gemini/bin" "$fixture/mock-bin"

cat > "$fixture/agy.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--version") == 0) {
    puts("agy version " AGY_VERSION);
    return 0;
  }
  const char *path = getenv("AGY_CALL_LOG");
  FILE *log = path ? fopen(path, "a") : NULL;
  if (log) {
    fprintf(log, "%s\n", argc > 1 ? argv[1] : "no-args");
    fclose(log);
  }
  return 0;
}
C
cc -DAGY_VERSION='"1.4.9"' "$fixture/agy.c" -o "$HOME/.gemini/bin/agy"
cc -DAGY_VERSION='"1.5.0"' "$fixture/agy.c" -o "$fixture/agy-new"

cat > "$fixture/mock-bin/graftcp" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == --help ]]; then
  echo '--socks5 --http_proxy --select_proxy_mode'
  exit 0
fi
printf '%s\n' "$*" >> "$GRAFTCP_CALL_LOG"
while [[ "${1:-}" == --* ]]; do shift; done
exec "$@"
SH
cat > "$fixture/mock-bin/curl" <<'SH'
#!/usr/bin/env bash
printf '400'
SH
chmod +x "$fixture/mock-bin/graftcp" "$fixture/mock-bin/curl"
export GRAFTCP_BIN="$fixture/mock-bin/graftcp"
export PATH="$fixture/mock-bin:$PATH"

target="$HOME/.gemini/bin/agy"
backup="$target.antiagy-original"
bash "$repo_dir/antiagy.sh" check socks5://127.0.0.1:10808 >/dev/null
[[ ! -e "$backup" ]]

bash "$repo_dir/antiagy.sh" install socks5://127.0.0.1:10808 >/dev/null
[[ -f "$backup" ]]
[[ "$("$target" --version)" == 'agy version 1.4.9' ]]
"$target" --hub --hub-port=12345
grep -Fq -- '--socks5=127.0.0.1:10808' "$GRAFTCP_CALL_LOG"
grep -Fxq -- '--hub' "$AGY_CALL_LOG"

bash "$repo_dir/antiagy.sh" install http://127.0.0.1:8080 >/dev/null
[[ "$("$backup" --version)" == 'agy version 1.4.9' ]]
"$target" --hub
grep -Fq -- '--http_proxy=127.0.0.1:8080' "$GRAFTCP_CALL_LOG"

# Simulate an IDE update replacing the wrapper with a newer native agy.
cp "$fixture/agy-new" "$target"
[[ "$(bash "$repo_dir/antiagy.sh" status | sed -n 's/^状态：//p')" == updated ]]
bash "$repo_dir/antiagy.sh" install socks5://127.0.0.1:10808 >/dev/null
[[ "$("$backup" --version)" == 'agy version 1.5.0' ]]
compgen -G "${backup}.previous.*" >/dev/null

bash "$repo_dir/antiagy.sh" restore >/dev/null
[[ ! -e "$backup" ]]
[[ "$("$target" --version)" == 'agy version 1.5.0' ]]

if bash "$repo_dir/antiagy.sh" install socks5://127.0.0.1:0 >/dev/null 2>&1; then
  echo 'invalid proxy unexpectedly accepted' >&2
  exit 1
fi
[[ ! -e "$backup" ]]
echo 'antiagy integration smoke test passed'
