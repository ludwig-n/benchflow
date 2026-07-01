#!/bin/bash
# Harbor server bootstrap — essential plumbing then start server.
# First arg is WORKDIR (container cwd), rest are server args.
export WORKDIR="${1:-/app}"; shift
export HARBOR_STAGING="/staging/env_files"
mkdir -p "$WORKDIR"

export DEBIAN_FRONTEND=noninteractive

# --- Create log folders that benchflow expects ---
mkdir -p /logs/verifier /logs/agent /logs/artifacts

# --- Fix "Could not switch group" error during apt installs ---
echo 'APT::Sandbox::User "root";' >/etc/apt/apt.conf.d/sandbox-disable

# --- Fix "Insecure $ENV{PATH} while running with -T switch" error during some apt installs ---
# https://www.mail-archive.com/debian-bugs-dist@lists.debian.org/msg2068674.html
sed -i '1a BEGIN { $ENV{PATH} = "/usr/sbin:/usr/bin:/sbin:/bin"; }' /usr/sbin/adduser

# --- Set up wrappers for apt and apt-get that pipe `yes` into all apt commands. Fixes some apt installs hanging ---
echo '#!/bin/bash
yes | /usr/bin/apt "$@"' >/usr/local/bin/apt
echo '#!/bin/bash
yes | /usr/bin/apt-get "$@"' >/usr/local/bin/apt-get
chmod +x /usr/local/bin/apt /usr/local/bin/apt-get

# --- Set up a mirror for Maven Central to prevent 429 errors for tasks that use Maven ---
if [ ! -f ~/.m2/settings.xml ]; then
    mkdir -p ~/.m2
    echo '
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
          https://maven.apache.org/xsd/settings-1.0.0.xsd">
  <mirrors>
    <mirror>
      <id>central</id>
      <name>Google Cloud Storage mirror of Maven Central</name>
      <url>https://maven-central.storage-download.googleapis.com/maven2/</url>
      <mirrorOf>central</mirrorOf>
    </mirror>
  </mirrors>
</settings>
' >~/.m2/settings.xml
fi

# --- Refresh package index once (apt-based images) ---
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq 2>/dev/null || true
fi

# --- Ensure /usr/bin/python3 exists ---
_SYS_PY=/usr/bin/python3
if [ ! -x "$_SYS_PY" ]; then
  echo "[harbor] /usr/bin/python3 not found, installing..." >&2
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y -qq python3 python3-venv 2>/dev/null || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache python3 2>/dev/null || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3 2>/dev/null || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 2>/dev/null || true
  fi
  if [ ! -x "$_SYS_PY" ]; then
    echo "[harbor] FATAL: cannot install /usr/bin/python3" >&2
    exit 1
  fi
fi

# --- Create an isolated venv for the Harbor server at /opt/harbor-server ---
_HARBOR_VENV=/opt/harbor-server
_HARBOR_PY="$_HARBOR_VENV/bin/python3"
if [ ! -x "$_HARBOR_PY" ]; then
  echo "[harbor] Creating server venv at $_HARBOR_VENV..." >&2
  "$_SYS_PY" -m venv --without-pip "$_HARBOR_VENV" \
    || { echo "[harbor] FATAL: cannot create server venv" >&2; exit 1; }
  # Bootstrap pip into the venv (try multiple strategies)
  if "$_HARBOR_PY" -c "import ensurepip" 2>/dev/null; then
    "$_HARBOR_PY" -m ensurepip --default-pip 2>/dev/null || true
  fi
  if ! "$_HARBOR_PY" -m pip --version 2>/dev/null; then
    # Try using system pip to install pip into the venv
    if "$_SYS_PY" -m pip --version 2>/dev/null; then
      echo "[harbor] Bootstrapping pip from system pip..." >&2
      "$_SYS_PY" -m pip install --prefix="$_HARBOR_VENV" --no-deps --force-reinstall pip 2>/dev/null || true
    fi
  fi
  if ! "$_HARBOR_PY" -m pip --version 2>/dev/null; then
    echo "[harbor] Bootstrapping pip via get-pip.py..." >&2
    "$_HARBOR_PY" -c "
import urllib.request, socket
socket.setdefaulttimeout(15)
urllib.request.urlretrieve('https://bootstrap.pypa.io/get-pip.py', '/tmp/get-pip.py')
" 2>/dev/null \
      && "$_HARBOR_PY" /tmp/get-pip.py --quiet 2>/dev/null \
      || { echo "[harbor] FATAL: cannot bootstrap pip" >&2; exit 1; }
  fi
fi

if ! "$_HARBOR_PY" -c "import uvicorn; import fastapi" 2>/dev/null; then
  echo "[harbor] Installing server dependencies (uvicorn/fastapi)..." >&2
  "$_HARBOR_PY" -m pip install --upgrade pip 2>/dev/null || true
  "$_HARBOR_PY" -m pip install uvicorn fastapi 2>/dev/null \
    || { echo "[harbor] WARNING: failed to install uvicorn/fastapi, server may fail" >&2; }
fi

export HARBOR_PYTHON="$_HARBOR_PY"

# --- Install tmux & asciinema (for terminal-based agents) ---
export TMUX_TMPDIR="${TMUX_TMPDIR:-/tmp/.harbor-tmux}"
mkdir -p "$TMUX_TMPDIR"

for f in "$HOME/.bashrc" "$HOME/.bash_profile"; do
  [ -f "$f" ] || touch "$f"
  grep -q 'TMUX_TMPDIR' "$f" 2>/dev/null || echo "alias tmux='tmux -S $TMUX_TMPDIR/default'" >> "$f"
done

if ! command -v tmux >/dev/null 2>&1; then
  echo "[harbor] Installing tmux..." >&2
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y -qq tmux 2>/dev/null || true
  elif command -v dnf >/dev/null 2>&1; then dnf install -y tmux 2>/dev/null || true
  elif command -v yum >/dev/null 2>&1; then yum install -y tmux 2>/dev/null || true
  elif command -v apk >/dev/null 2>&1; then apk add --no-cache tmux 2>/dev/null || true
  fi
fi
if ! command -v asciinema >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y -qq asciinema 2>/dev/null || true
  elif command -v pip3 >/dev/null 2>&1; then
    pip3 install --break-system-packages asciinema 2>/dev/null || pip3 install asciinema 2>/dev/null || true
  fi
fi

# --- Install ncat to run ACP servers ---
if ! command -v ncat >/dev/null 2>&1; then
  echo "[harbor] Installing ncat..." >&2
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y -qq ncat 2>/dev/null || true
  elif command -v dnf >/dev/null 2>&1; then dnf install -y nmap-ncat 2>/dev/null || true
  elif command -v yum >/dev/null 2>&1; then yum install -y nmap-ncat 2>/dev/null || true
  elif command -v apk >/dev/null 2>&1; then apk add --no-cache ncat 2>/dev/null || true
  fi
fi

# --- Run task-specific setup (sourced so it can export/override HARBOR_PYTHON) ---
if [ -f "$HARBOR_STAGING/setup.sh" ]; then
  echo "[harbor] Running task setup.sh..." >&2
  source "$HARBOR_STAGING/setup.sh"
fi

# Re-verify after setup.sh (the /opt/harbor-server venv should be untouched,
# but check anyway in case something unusual happened)
if ! "$HARBOR_PYTHON" -c "import uvicorn; import fastapi" 2>/dev/null; then
  echo "[harbor] WARNING: uvicorn/fastapi lost after setup.sh, server may fail" >&2
fi

exec "$HARBOR_PYTHON" "$@"
