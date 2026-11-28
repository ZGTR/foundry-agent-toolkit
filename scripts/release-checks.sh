#!/usr/bin/env bash
# Release checks: this repository's full checks. scripts/promote.sh runs this file, from the commit being
# promoted, in a fresh worktree next to the checkout, and records a green run as a receipt for that tree.
set -euo pipefail
# Mirrors .github/workflows/ci.yml: jobs verify (Python 3.11, 3.12, 3.13 on Linux), infrastructure,
# consumer-gate and container. The paid live-evaluation workflow (evaluate.yml) is not a check.
export PATH="$HOME/.local/bin:$PATH"
command -v uv >/dev/null || { echo "release-checks: uv is required (https://docs.astral.sh/uv/)" >&2; exit 2; }
mkdir -p artifacts

# Job verify, once per Python version of its matrix.
for py in 3.11 3.12 3.13; do
  echo "== verify on Python $py"
  export UV_PROJECT_ENVIRONMENT=".release-venv/$py"
  rm -rf dist
  uv sync --frozen --extra bedrock --python "$py"
  uv run --frozen --extra bedrock ruff check .
  uv run --frozen --extra bedrock ruff format --check .
  uv run --frozen --extra bedrock mypy
  uv run --frozen --extra bedrock python scripts/verify_mutation.py
  uv run --frozen --extra bedrock python -c "import subprocess,sys; subprocess.run([sys.executable,'-m','pytest','-vv','-o','faulthandler_timeout=30','--durations=10','--cov','--cov-report=term-missing','--cov-report=xml'],check=True,timeout=120)"
  uv run --frozen --extra bedrock python -m build --no-isolation
  uv run --frozen --extra bedrock agent-tdd evaluate --cases evals/refund-routing.json --provider scripted --report artifacts/smoke.json --repeats 3
done
unset UV_PROJECT_ENVIRONMENT

# Job infrastructure: the checksum-pinned OpenTofu from scripts/install_tofu.py.
python3 scripts/install_tofu.py --directory .release-tools
tofu=$PWD/.release-tools/tofu
"$tofu" -chdir=infra/aws fmt -check -recursive
"$tofu" -chdir=infra/aws init -backend=false -lockfile=readonly
"$tofu" -chdir=infra/aws validate
"$tofu" -chdir=infra/aws test

# Job consumer-gate: what action.yml does, on Python 3.12 with no dependencies of its own.
python3.12 -m venv .release-venv/action
.release-venv/action/bin/python -m pip install -q --disable-pip-version-check --no-deps .
gate() { # gate <cases> <executor-config> <report>: the action's inputs, with its defaults
  PATH="$PWD/.release-venv/action/bin:$PATH" GATE_CASES="$1" GATE_EXECUTOR_CONFIG="$2" GATE_REPORT="$3" \
    GATE_SPLIT=release GATE_REPEATS=1 GATE_MAX_REQUESTS=100 GATE_MAX_MODEL_CALLS=8 GATE_TIMEOUT=30 \
    GATE_MAX_LATENCY=60 GATE_MIN_PASS_RATE=1 GATE_MAX_REGRESSION=0 \
    python scripts/run_ci_gate.py; }
gate evals/ci-echo.json examples/ci/node.json artifacts/node.json
gate evals/ci-echo.json examples/ci/python.json artifacts/python.json
python3 -c "import json,pathlib; p=pathlib.Path('evals/ci-echo.json'); d=json.loads(p.read_text()); d['cases'][1]['expected']['output']='intentional mismatch'; pathlib.Path('artifacts/failing-cases.json').write_text(json.dumps(d))"
if gate artifacts/failing-cases.json examples/ci/node.json artifacts/rejected.json; then
  echo "release-checks: the deliberately failing expectation passed the gate" >&2; exit 1; fi
echo "consumer-gate: the failing expectation was rejected, as required"

# Docker. A machine with the daemon installed but not running (a cloud sandbox) gets it started; Docker Hub
# images come through a mirror there, because shared egress IPs hit Docker Hub's anonymous rate limit.
if ! docker info >/dev/null 2>&1 && [ "$(id -u)" = 0 ] && command -v dockerd >/dev/null; then
  mirror=--registry-mirror=https://mirror.gcr.io
  grep -qs registry-mirrors /etc/docker/daemon.json && mirror=
  (dockerd $mirror >/tmp/release-checks-dockerd.log 2>&1 &)
  for _ in $(seq 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
fi
docker info >/dev/null 2>&1 || { echo "UNPROVEN: the remaining steps need a Docker daemon"; exit 3; }
# Job container, both matrix arms.
for bedrock in false true; do
  docker build ${PIP_CERT:+--secret id=proxy_ca,src="$PIP_CERT"} --build-arg WITH_BEDROCK="$bedrock" -t agent-tdd:release-checks .   # proxy_ca: the Dockerfile's optional CA for intercepted TLS
  python3 scripts/check_container.py agent-tdd:release-checks
  if [ "$bedrock" = true ]; then
    docker run --rm --read-only --network none --entrypoint python agent-tdd:release-checks \
      -c "import boto3; assert boto3.__version__ == '1.43.8'"
  fi
done
