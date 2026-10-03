#!/bin/bash
# serverX bench: pooled zero-alloc server vs stdlib HTTP::Server vs nginx.
# Same machine, same wrk client, warmup + median of N runs.
#
# Builds:
#   bin/serverx    single-threaded per process (fork-capable, -Dwithout_mt)
#   bin/serverx-mt multithreaded scheduler (CRYSTAL_WORKERS threads, no fork)
#
# Usage: ./bench.sh
#        THREADS=11 CONNS=256 DURATION=10 RUNS=3 ./bench.sh
set -e
cd "$(dirname "$0")"
export PATH=~/crystal/crystal-1.21.0-1/bin:$PATH

THREADS=${THREADS:-11}
CONNS=${CONNS:-256}
DURATION=${DURATION:-10}
RUNS=${RUNS:-3}
PORT=${PORT:-4510}
MT_WORKERS=${MT_WORKERS:-8}

echo "# building (release)..."
crystal build --release -Dwithout_mt -o bin/serverx src/serverx.cr 2>/dev/null
crystal build --release -o bin/serverx-mt src/serverx.cr 2>/dev/null

# bench <label> <binary> <impl> <workers> <mt_workers_env|-> <conns>
bench() {
  local label=$1 bin=$2 impl=$3 workers=$4 mtenv=$5 conns=$6
  local log=/tmp/serverx_${label}.log
  if [ "$mtenv" = "-" ]; then
    ./bin/$bin --impl "$impl" --workers "$workers" --port $PORT --stats-interval 3 &>"$log" &
  else
    CRYSTAL_WORKERS=$mtenv ./bin/$bin --impl "$impl" --workers 1 --port $PORT --stats-interval 3 &>"$log" &
  fi
  local pid=$!
  for _ in $(seq 1 100); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done

  wrk -t$THREADS -c$conns -d3 --latency "http://127.0.0.1:$PORT/" &>/dev/null # warmup

  local rps=()
  for _ in $(seq 1 $RUNS); do
    out=$(wrk -t$THREADS -c$conns -d$DURATION --latency "http://127.0.0.1:$PORT/")
    rps+=("$(echo "$out" | awk '/Requests\/sec/ {print $2}')")
    if [ -z "${rps[-1]}" ]; then echo "wrk parse failed"; echo "$out"; exit 1; fi
  done
  local median lat p99
  median=$(printf '%s\n' "${rps[@]}" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')
  lat=$(echo "$out" | awk '/Latency/ {print $2 $3; exit}')
  p99=$(echo "$out" | awk '/ 99%/ {print $2 $3; exit}')

  sleep 3.2 # one more stats window
  local pids
  pids=$(ps -o pid= --ppid $pid; echo $pid)
  for p in $pids; do kill $p 2>/dev/null || true; done
  wait $pid 2>/dev/null || true

  # Last-line rss_kb per pid, summed
  local rss_kb
  rss_kb=$(grep '^# stats' "$log" | tac | awk '{pid=$4; sub("pid=","",pid)
      if (!seen[pid]++) {r=$NF; sub("rss_kb=","",r); sum+=r}}
      END {print sum+0}')
  # GC churn under load: per pid, sum gc_win_kb over windows where reqs_win>0,
  # divided by (active windows * 3s). The "GC keeps churning" metric.
  local churn
  churn=$(grep '^# stats' "$log" | awk '{qw=$6; sub("reqs_win=","",qw); gw=$8; sub("gc_win_kb=","",gw); pid=$4
      if (!(first[pid]++)) next  # skip boot window (runtime warmup allocations)
      if (qw+0 > 0) {gc[pid]+=gw; n[pid]++}}
      END {act=0; tot=0; for (p in gc) {tot+=gc[p]; act+=n[p]}
      if (act>0) printf "%.0f", tot/(act*3); else print 0}')
  # total requests served
  local reqs
  reqs=$(grep '^# stats' "$log" | awk '{r=$5; sub("reqs=","",r); pid=$4; sub("pid=","",pid); last[pid]=r}
      END {for (p in last) sum+=last[p]; print sum+0}')

  echo "$label conns=$conns rps_median=$median latency_avg=$lat p99=$p99 rss_total_kb=$rss_kb gc_churn_kb_per_s=$churn reqs_total=$reqs"
}

# bench_nginx <workers|auto> <conns> — reference nginx in docker (same payload)
bench_nginx() {
  local workers=$1 conns=$2 port=4580
  sed "s/WORKERS/$workers/" nginx.conf.tpl > /tmp/sx_nginx.conf
  docker rm -f serverx-nginx &>/dev/null || true
  docker run -d --name serverx-nginx -p $port:80 \
    -v /tmp/sx_nginx.conf:/etc/nginx/nginx.conf:ro nginx:alpine &>/dev/null
  for _ in $(seq 1 100); do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.2; done

  wrk -t$THREADS -c$conns -d3 --latency "http://127.0.0.1:$port/" &>/dev/null # warmup
  local rps=()
  for _ in $(seq 1 $RUNS); do
    out=$(wrk -t$THREADS -c$conns -d$DURATION --latency "http://127.0.0.1:$port/")
    rps+=("$(echo "$out" | awk '/Requests\/sec/ {print $2}')")
  done
  local median lat p99
  median=$(printf '%s\n' "${rps[@]}" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')
  lat=$(echo "$out" | awk '/Latency/ {print $2 $3; exit}')
  p99=$(echo "$out" | awk '/ 99%/ {print $2 $3; exit}')
  docker rm -f serverx-nginx &>/dev/null || true
  echo "nginx workers=$workers conns=$conns rps_median=$median latency_avg=$lat p99=$p99 rss_total_kb=- gc_churn_kb_per_s=0 (no GC) reqs_total=-"
}

echo "# serverx bench threads=$THREADS conns=$CONNS duration=${DURATION}s runs=$RUNS"
echo "# cpu: $(nproc) cores; wrk shares the same cores"

# single-threaded processes (fork model, like nginx workers)
bench stdlib_st_w1     serverx    stdlib 1 -  $CONNS
bench pooled_st_w1     serverx    pooled 1 -  $CONNS
bench stdlib_st_w8     serverx    stdlib 8 -  $CONNS
bench pooled_st_w8     serverx    pooled 8 -  $CONNS

# multithreaded scheduler (one process, CRYSTAL_WORKERS threads)
bench stdlib_mt_t8     serverx-mt stdlib 1 $MT_WORKERS $CONNS
bench pooled_mt_t8     serverx-mt pooled 1 $MT_WORKERS $CONNS

# high connections
bench stdlib_st_w8_c1024 serverx    stdlib 8 -   1024
bench pooled_st_w8_c1024 serverx    pooled 8 -   1024
bench pooled_mt_t8_c1024 serverx-mt pooled 1 $MT_WORKERS 1024

# nginx reference (docker, +NAT overhead)
bench_nginx 1    $CONNS
bench_nginx auto $CONNS
bench_nginx auto 1024
