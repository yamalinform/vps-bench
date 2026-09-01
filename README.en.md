*[По-русски](README.md)*

# vpsbench

A tool for standardized VPS testing: CPU, cryptography, memory, disk, network, plus a
profile of the hardware and the hypervisor.

All the tests (fio, sysbench, iperf3 and others) are pinned inside a single Docker image
addressed by digest, so results from different servers can be compared correctly.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/yamalinform/vps-bench/main/run.sh -o run.sh && bash run.sh
```

The script asks for the parameters it needs in the terminal. A quick test takes 5 to 10
minutes depending on the CPU, a full one about 40 minutes.

⚠️ **Over SSH, use `--detach`.** Otherwise a dropped connection kills the whole run and
forty minutes of work are gone. With that flag the run goes to the background and its
progress is written to `~/vpsbench-detached.log`:

```bash
bash run.sh --detach --yes --install-docker yes --depth full --vantage "my-vps-1"
```

## How it works

* **Docker as the environment.** All the tools run inside a container. If Docker is not
  installed, the script offers to install it and removes it afterwards
  (if Docker was already there, it is left alone).
* **Privileges.** The container runs with `--privileged` and `--network host`: that is
  required for direct access to the host disk and network, otherwise the container would
  be measured instead of the server.
  ⚠️ With those flags there is no isolation at all. The container here is a way to
  deliver tools with root privileges, not a sandbox. If that is not acceptable to you,
  this tool is not for you, and it is fairer to say so here than to bury it in the fine
  print.
* **Privacy.** Results are **never sent anywhere**. No telemetry, no accounts,
  everything stays local. The script reaches out to three places only, and the list is
  printed on screen before anything starts: `ghcr.io` for the image, your own system
  repositories (only if Docker has to be installed), and the speed test endpoints.

## Network measurement

A fair measurement of your link needs a second machine (your laptop or another server
will do). It needs `run.sh` as well:

```bash
# On the second machine:
curl -fsSL https://raw.githubusercontent.com/yamalinform/vps-bench/main/run.sh -o run.sh
bash run.sh --agent
```

It brings up the receiving side (three ports, not a single package installed) and holds
it until you press Ctrl-C. On the main server, give it that IP when the script asks
about the network.

*Public endpoints (Cloudflare, Debian and Yandex mirrors) are measured **always**,
whether or not you have a second machine, and they go into a separate section of the
report. They measure the path to somebody else's service rather than your own link, so
they neither replace the measurement to your second machine nor get mixed with it.*

## What you get

In `~/vpsbench-report-<label>/`:
* `.md`: the text profile of the server, the primary format, convenient for `diff`;
* `.html`: the same profile for reading with your eyes (opens in a browser, no internet needed);
* `.json`: data for scripts and for building dashboards;
* `raw-run/`: the raw logs, the report can be rebuilt from them.

*If a metric's spread across repeats exceeds 20%, it is marked UNRELIABLE. A metric that
could not be measured stays in the report as a "not measured" line instead of
disappearing, otherwise two reports could not be compared line by line.*

## Running without questions (for scripts)

```bash
bash run.sh --yes --install-docker yes --depth quick --vantage "my-vps-1"
```

⚠️ `--yes` only answers the question about starting the measurement. Installing Docker
is deliberately kept out of it, so in a script you have to allow it separately with
`--install-docker yes`, otherwise the run stops with a message saying it cannot measure
anything without Docker.

Main flags:
* `--depth quick|full`: how thorough the test is;
* `--vantage NAME`: the server name used in the report;
* `--target LABEL:IP`: address of the second machine running `--agent`;
* `--impact bench|observe`: full load, or a gentle mode for a server that is in service;
* `--no-network`: skip the measurement to the second machine (public endpoints are still measured);
* `--install-docker yes|no`: whether to install Docker automatically;
* `--detach`: run in the background and return the prompt immediately;
* `--update yes|no` / `--reboot yes|no`: whether to upgrade or reboot the OS (default is `no`).

If there is no terminal and no flag is given, the safe answer is taken and the script
says so out loud. Without an explicit `--update yes` it will not upgrade the system, and
without `--reboot yes` it will not reboot the machine.

## Comparing servers

Reports are compared on your own machine, not on the server under test: after cleanup
only the results folder is left there, no code. You will need a clone of the repository
and `python3`:

```bash
git clone https://github.com/yamalinform/vps-bench.git && cd vps-bench

# Compare two servers (the arguments are the raw-run folders from their reports):
python3 assemble.py --compare ~/vpsbench-report-A/raw-run ~/vpsbench-report-B/raw-run --out diff.md

# Build an HTML dashboard from a folder with .json files from several reports:
python3 dashboard/build.py folder-with-json/ --out dashboard.html
```

The comparison first checks whether comparing is meaningful at all: same tool version,
same measuring tool versions, same run mode, same set of public endpoints. A difference
that does not exceed the metric's own spread is marked as insignificant.

## Requirements

* Linux x86_64 (the distribution does not matter);
* Docker, or `apt` so the script can install it;
* root or `sudo`;
* about 1.5 GB of free disk space.

## License

MIT
