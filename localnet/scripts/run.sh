#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
harmony_dir="$(go env GOPATH)/src/github.com/harmony-one/harmony"
localnet_config=$(realpath "$DIR/../configs/localnet_deploy.config")

function stop() {
  if [ "$KEEP" == "true" ]; then
    tail -f /dev/null
  fi
  kill_localnet
}

function kill_localnet() {
  pushd "$(pwd)"
  cd "$harmony_dir" && bash ./test/kill_node.sh
  popd
}

function setup() {
  if [ ! -d "$harmony_dir" ]; then
    echo "Test setup FAILED: Missing harmony directory at $harmony_dir"
    exit 1
  fi
  if [ ! -f "$localnet_config" ]; then
    echo "Test setup FAILED: Missing localnet deploy config at $localnet_config"
    exit 1
  fi
  kill_localnet
  error=0  # reset error/exit code
}

function build_and_start_localnet() {
  local localnet_log="$harmony_dir/localnet_deploy.log"
  rm -rf "$harmony_dir/tmp_log*"
  rm -rf "$harmony_dir/.dht*"
  rm -f "$localnet_log"
  rm -f "$harmony_dir/*.rlp"
  pushd "$(pwd)"
  cd "$harmony_dir"
  if [ "$BUILD" == "true" ]; then
    # Dynamic for faster build iterations
    bash ./scripts/go_executable_build.sh -S
    BUILD=False
  fi
  bash ./test/deploy.sh -B -D 60000 "$localnet_config" 2>&1 | tee "$localnet_log"
  popd
}

function go_tests() {
  echo -e "\n=== \e[38;5;0;48;5;255mSTARTING GO TESTS\e[0m ===\n"
  pushd "$(pwd)"
  cd "$harmony_dir"
  if [ "$BUILD" == "true" ]; then
    # Dynamic for faster build iterations
    bash ./scripts/go_executable_build.sh -S
    BUILD=False
  fi
  bash ./scripts/travis_checker.sh || error=1
  echo -e "\n=== \e[38;5;0;48;5;255mFINISHED GO TESTS\e[0m ===\n"
  popd
}

function rpc_tests() {
  echo -e "\n=== \e[38;5;0;48;5;255mSTARTING RPC TESTS\e[0m ===\n"
  build_and_start_localnet || exit 1 &
  sleep 20
  wait_for_localnet_boot 100 # Timeout at ~300 seconds

  echo "Starting test suite..."
  sleep 3
  # Use 4 or less threads, high thread count can lead to burst RPC calls, which can lead to some RPC calls being rejected.
  cd "$DIR/../" && python3 -u -m py.test -v -r s -s rpc_tests -x -n 4 || error=1
  echo -e "\n=== \e[38;5;0;48;5;255mFINISHED RPC TESTS\e[0m ===\n"
}

function rosetta_tests() {
  echo -e "\n=== \e[38;5;0;48;5;255mSTARTING ROSETTA API TESTS\e[0m ===\n"
  build_and_start_localnet || exit 1 &
  sleep 30
  wait_for_localnet_boot 100 # Timeout at ~300 seconds

  echo "Starting test suite..."
  sleep 3
  # Run tests sequentially for clear error tracing
  rosetta-cli check:construction --configuration-file "$DIR/../configs/localnet_rosetta_test_s0.json" || error=1
  rosetta-cli check:data --configuration-file "$DIR/../configs/localnet_rosetta_test_s0.json" || error=1
  rosetta-cli check:construction --configuration-file "$DIR/../configs/localnet_rosetta_test_s1.json" || error=1
  rosetta-cli check:data --configuration-file "$DIR/../configs/localnet_rosetta_test_s1.json" || error=1
  echo -e "\n=== \e[38;5;0;48;5;255mFINISHED ROSETTA API TESTS\e[0m ===\n"
}

function wait_for_localnet_boot() {
  timeout=70
  if [ -n "$1" ]; then
    timeout=$1
  fi
  i=0
  until curl --silent --location --request POST "localhost:9500" \
    --header "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' >/dev/null; do
    echo "Trying to connect to localnet..."
    if ((i > timeout)); then
      echo "TIMEOUT REACHED"
      exit 1
    fi
    sleep 3
    i=$((i + 1))
  done

  valid=false
  until $valid; do
    result=$(curl --silent --location --request POST "localhost:9500" \
      --header "Content-Type: application/json" \
      --data '{"jsonrpc":"2.0","method":"hmy_blockNumber","params":[],"id":1}' | jq '.result')
    if [ "$result" = "\"0x0\"" ]; then
      echo "Waiting for localnet to boot..."
      if ((i > timeout)); then
        echo "TIMEOUT REACHED"
        exit 1
      fi
      sleep 3
      i=$((i + 1))
    else
      valid=true
    fi
  done

  sleep 15  # Give some slack to ensure localnet is booted...
  echo "Localnet booted."
}

trap stop SIGINT SIGTERM EXIT

BUILD=true
KEEP=false
GO=true
RPC=true
ROSETTA=true

while getopts "Bkgnr" option; do
  case ${option} in
  B) BUILD=false ;;
  k) KEEP=true ;;
  g) RPC=false
     ROSETTA=false
  ;;
  n)
    GO=false
    ROSETTA=false
  ;;
  r)
    GO=false
    RPC=false
  ;;
  *) echo "
Integration tester for localnet

Option:      Help:
-B           Do NOT build binray before testing
-k           Keep localnet running after Node API tests are finished
-g           ONLY run go tests & checks
-n           ONLY run the RPC tests
-r           ONLY run the rosetta API tests
"
  exit 0
  ;;
  esac
done

setup

if [ "$GO" == "true" ]; then
  go_tests
fi

if [ "$RPC" == "true" ]; then
  rpc_tests
fi

if [ "$ROSETTA" == "true" ]; then
  rosetta_tests
fi

exit "$error"
