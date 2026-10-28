#!/bin/zsh
# Local Cloudflare runtime for tests:  test/dev-server.sh start | stop | kill
# State persists in /tmp/cruiselan-games-state so restarts keep rooms (the restart test relies on it).
cd ${0:A:h:h}
case "$1" in
  start)
    # A throwaway signing key and a fake APNs (test/apns-mock.mjs), so tests never reach Apple.
    if [ ! -f .dev.vars ]; then
      key=$(openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt | awk 'NF' ORS='\\n')
      printf 'APNS_MOCK=http://localhost:9911\nAPNS_KEY="%s"\n' "$key" > .dev.vars
    fi
    WRANGLER_SEND_METRICS=false CI=1 nohup node node_modules/wrangler/bin/wrangler.js dev --port 8787 \
      --persist-to /tmp/cruiselan-games-state >> /tmp/cruiselan-games-dev.log 2>&1 < /dev/null &
    for i in {1..40}; do sleep 1; [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' localhost:8787/v1/health)" = "200" ] && { echo "dev server ready"; exit 0; }; done
    echo "dev server did not start; see /tmp/cruiselan-games-dev.log"; exit 1 ;;
  stop|kill)
    pkill -9 -f "wrangler.js dev --port 8787" ; pkill -9 -f "wrangler-dist/cli.js dev --port 8787" ; pkill -9 -f "workerd serve" ; sleep 1; echo "dev server stopped" ;;
esac
