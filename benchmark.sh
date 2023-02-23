#!/usr/bin/env bash

set -euo pipefail

# Inspired by: https://sled.rs/perf.html#experimental-design

BENCHMARK_WORKLOAD1="bench-mp-logging10"
BENCHMARK_WORKLOAD2="bench-mp-fast-logger10"
BENCHMARK_NUMBER_OF_RUNS=5
# TODO: +RTS --nonmoving-gc ?
BENCHMARK_GHC_OPTS=("-threaded" "-rtsopts" "-with-rtsopts=-N")
BENCHMARK_CABAL_BUILD_OPTS=("--enable-benchmarks"
                            "--disable-profiling"
                            "-O2"
                            "--ghc-options=${BENCHMARK_GHC_OPTS[*]}")
BENCHMARK_CABAL_RUN_OPTS=("-O2"
                          "--ghc-options=${BENCHMARK_GHC_OPTS[*]}")
BENCHMARK_PERF_EVENTS="L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses,dTLB-loads,dTLB-load-misses"

# Save info about current hardware and OS setup.
uname --kernel-name --kernel-release --kernel-version --machine --operating-system
echo ""
lscpu
echo ""

# Warn about non-essential programs...
FIREFOX_PID="$(pgrep GeckoMain)"
if [ -n "${FIREFOX_PID}" ]; then
    read -r -p "Firefox is running, wanna kill it? [y/N] " yn
    case $yn in
        [Yy]*) kill -1 "${FIREFOX_PID}" ;;
        *) ;;
    esac
fi

if [ -f "/tmp/${BENCHMARK_WORKLOAD1}.txt" ] || [ -f "/tmp/${BENCHMARK_WORKLOAD2}.txt" ]; then
    read -r -p "Old benchmark results exist, wanna remove them? [y/N] " yn
    case $yn in
        [Yy]*) rm -f "/tmp/${BENCHMARK_WORKLOAD1}.txt";
               rm -f "/tmp/${BENCHMARK_WORKLOAD2}.txt" ;;
        *) ;;
    esac
fi

# Use the performance governor instead of powersave (for laptops).
for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    echo "${policy}"
    echo "performance" | sudo tee "${policy}/scaling_governor"
done

# Compile workloads.

# XXX: enable benchmarking against old versions of same test
# BENCHMARK_GITHASH1="XXX: NOT USED YET"
# BENCHMARK_GITHASH2="XXX: NOT USED YET"
# BENCHMARK_BIN1="/tmp/${BENCHMARK_GITHASH1}-${BENCHMARK_WORKLOAD1}"
# BENCHMARK_BIN2="/tmp/${BENCHMARK_GITHASH2}-${BENCHMARK_WORKLOAD2}"
# if [ -n "${BENCHMARK_GITHASH1}" ] && [ ! -f "${BENCHMARK_BIN1}" ] ; then
#     git checkout "${BENCHMARK_GITHASH1}"
#     cabal build -O2 "${BENCHMARK_WORKLOAD1}"
#     cp $(cabal list-bin "${BENCHMARK_WORKLOAD1}") "${BENCHMARK_BIN1}"
# fi

cabal build "${BENCHMARK_CABAL_BUILD_OPTS[@]}" "${BENCHMARK_WORKLOAD2}"

# Disable turbo boost.
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo

# The following run is just a (CPU) warm up, the results are discarded.
cabal run "${BENCHMARK_CABAL_RUN_OPTS[@]}" "${BENCHMARK_WORKLOAD2}"

# Run the benchmarks. By running workloads interleaved with each other, we
# reduce the risk of having particular transient system-wide effects impact only
# a single measurement.
for i in $(seq ${BENCHMARK_NUMBER_OF_RUNS}); do
    echo "Running benchmark run ${i}"
    perf stat --event="${BENCHMARK_PERF_EVENTS}" \
         cabal run "${BENCHMARK_CABAL_RUN_OPTS[@]}" "${BENCHMARK_WORKLOAD1}" \
         2>&1 | tee --append "/tmp/${BENCHMARK_WORKLOAD1}.txt"
    perf stat --event="${BENCHMARK_PERF_EVENTS}" \
         cabal run "${BENCHMARK_CABAL_RUN_OPTS[@]}" "${BENCHMARK_WORKLOAD2}" \
         2>&1 | tee --append "/tmp/${BENCHMARK_WORKLOAD2}.txt"

    # XXX: Can't get the below to work, ${BENCHMARK_WORKLOAD} env var doesn't
    # get interpolated correctly into the string?
    # Use `nice` to bump the priority of the benchmark process to the highest possible.
    ##sudo nice -n -20 su -c \
    ##     "perf stat -e cache-misses,branch-misses,dTLB-load-misses,iTLB-load-misses cabal run -O2 ${BENCHMARK_WORKLOAD1} >> /tmp/${BENCHMARK_WORKLOAD1}.txt" \
    ##     "${USER}"
    ##sudo nice -n -20 su -c \
    ##     "perf stat -e cache-misses,branch-misses,dTLB-load-misses,iTLB-load-misses cabal run -O2 ${BENCHMARK_WORKLOAD2} >> /tmp/${BENCHMARK_WORKLOAD2}.txt" \
    ##     "${USER}"

done

# Re-enable turbo boost.
echo 0 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo

# Go back to powersave governor.
for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    echo "${policy}"
    echo "powersave" | sudo tee "${policy}/scaling_governor"
done

# Output throughput data for R analysis.
R_FILE="/tmp/${BENCHMARK_WORKLOAD1}-${BENCHMARK_WORKLOAD2}.r"

echo 'Input=("' > "${R_FILE}"
{ echo "Workload Throughput";
  awk -v wl1="${BENCHMARK_WORKLOAD1}" \
      '/Throughput/ { print wl1, $2 }' "/tmp/${BENCHMARK_WORKLOAD1}.txt";
  awk -v wl2="${BENCHMARK_WORKLOAD2}" \
      '/Throughput/ { print wl2, $2 }' "/tmp/${BENCHMARK_WORKLOAD2}.txt";
  echo '")'
} >> "${R_FILE}"

cat << EOF >> "${R_FILE}"
Data = read.table(textConnection(Input),header=TRUE)
bartlett.test(Throughput ~ Workload, data=Data)

# If p-value >= 0.05, use var.equal=TRUE below

t.test(Throughput ~ Workload, data=Data,
       var.equal=TRUE,
       conf.level=0.95)
EOF

Rscript "${R_FILE}"

# Profiling

# On Linux install `perf` See
# https://www.kernel.org/doc/html/latest/admin-guide/perf-security.html for how
# to setup the permissions for using `perf`. Also note that on some systems,
# e.g. Ubuntu, `/usr/bin/perf` is not the actual binary but rather a bash script
# that calls the binary. Note that the steps in the admin guide needs to be
# performed on the binary and not the shell script. Since Linux 5.8 there's a
# special capability for capturing perf data called `cap_perfmon`, if you are on
# a older version you need `cap_sys_admin` instead.
#
# For more see: https://brendangregg.com/perf.html
